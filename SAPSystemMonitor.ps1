<#
.SYNOPSIS
    SAP System Monitor v2.0 (PowerShell + SAP .NET Connector / NCo 3.1)

.DESCRIPTION
    Agentless RFC-based health monitoring for S/4HANA, BW and ECC systems.
    PowerShell/NCo port of sap-jco-monitor (Java/JCo), mirroring the same checks,
    primary/fallback strategy, thresholds and exit codes.

    Checks: SM12 (locks), SM13 (updates), SMQ1 (qRFC), SM51 (servers),
            SM37 (aborted jobs), ST22 (short dumps), SMLG (dialog response time).

    Exit codes (max across all checks): 0 = OK, 1 = WARNING, 2 = CRITICAL.

.PARAMETER Destination
    Logical destination name. Resolved from "<Destination>.ncoDestination" in the
    current directory, else from a [<Destination>] section in sapnco.ini.

.PARAMETER OutputFormat
    Text (default), Markdown, or Json.

.PARAMETER NcoPath
    Folder containing sapnco.dll / sapnco_utils.dll (default D:\bwMonitoring).

.EXAMPLE
    .\SAPSystemMonitor.ps1 -Destination S4D
    .\SAPSystemMonitor.ps1 -Destination S4D -OutputFormat Markdown
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [ValidateSet("Text", "Markdown", "Json")]
    [string]$OutputFormat = "Text",

    [string]$NcoPath = "D:\bwMonitoring"
)

$ErrorActionPreference = "Stop"

# ---- thresholds / config (mirror sap-jco-monitor) ----
$VERSION          = "2.0"
$LOCK_WARN        = 5000
$JOB_WARN         = 10
$DUMP_WARN        = 10
$DUMP_CRIT        = 50
$RESPTIME_WARN_MS = 4000
$RESPTIME_LOOKBACK_DAYS = 14

$EXIT_OK = 0; $EXIT_WARNING = 1; $EXIT_CRITICAL = 2

# ============================================================
# Helpers
# ============================================================

function New-CheckResult {
    param([string]$Tx, [string]$Name)
    [PSCustomObject]@{
        Tx             = $Tx
        Name           = $Name
        Primary        = "-"
        PrimaryResult  = "-"
        Fallback       = "Not needed"
        FallbackResult = "-"
        Threshold      = "-"
        Status         = "OK"
        Code           = $EXIT_OK
        Detail         = @()
    }
}

# Convert a numeric status code to its label.
function Get-StatusText {
    param([int]$Code)
    switch ($Code) { 0 { "OK" } 1 { "WARNING" } 2 { "CRITICAL" } default { "UNKNOWN" } }
}

# Return the first non-empty value (NCo Attributes can come back blank before a call is made).
function Get-FirstNonEmpty {
    param($A, $B)
    if ($A) { $A } else { $B }
}

# Read destination parameters from "<name>.ncoDestination" or an sapnco.ini section.
function Get-DestinationConfig {
    param([string]$Name)

    $cfg = @{}
    $file = Join-Path (Get-Location).Path "$Name.ncoDestination"
    if (Test-Path $file) {
        Get-Content $file | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#") -and $line -match "^(.+?)=(.*)$") {
                $cfg[$matches[1].Trim().ToUpper()] = $matches[2].Trim()
            }
        }
        return $cfg
    }

    # fallback: [<name>] section in sapnco.ini (current dir, else NcoPath)
    $ini = Join-Path (Get-Location).Path "sapnco.ini"
    if (-not (Test-Path $ini)) { $ini = Join-Path $NcoPath "sapnco.ini" }
    if (Test-Path $ini) {
        $inSection = $false
        Get-Content $ini | ForEach-Object {
            $line = $_.Trim()
            if ($line -match "^\[(.+)\]$") {
                $inSection = ($matches[1] -eq $Name)
            }
            elseif ($inSection -and $line -match "^(.+?)=(.*)$") {
                $cfg[$matches[1].Trim().ToUpper()] = $matches[2].Trim()
            }
        }
    }
    return $cfg
}

# Create + invoke an RFC function, returning the IRfcFunction (caller reads its tables).
function Invoke-Rfc {
    param($Dest, [string]$FunctionName, [hashtable]$Imports = @{})
    $fn = $Dest.Repository.CreateFunction($FunctionName)
    foreach ($k in $Imports.Keys) { $fn.SetValue($k, $Imports[$k]) }
    $fn.Invoke($Dest)
    return $fn
}

# Append a row to an IRfcTable and set one field (NCo: Append() positions the cursor on the new row).
function Add-TableRow {
    param($Table, [string]$Field, $Value)
    [void]$Table.Append()   # Append() may return the new row; suppress so it can't leak into output
    $Table.SetValue($Field, $Value)
}

# ============================================================
# Checks (each returns a New-CheckResult object; never writes to host)
# ============================================================

# ---- SM12 : lock entries ----
function Test-Locks {
    param($Dest, [string]$Client)
    $r = New-CheckResult "SM12" "Lock Entries"
    $r.Threshold = "> $LOCK_WARN = WARNING"
    $r.Primary = "ENQUEUE_READ"
    try {
        $fn = Invoke-Rfc $Dest "ENQUEUE_READ" @{ GCLIENT = $Client }
        $count = $fn.GetTable("ENQ").RowCount
        $r.PrimaryResult = "$count active locks"
        if ($count -gt $LOCK_WARN) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
        return $r
    } catch {
        $r.PrimaryResult = "Not available"
        # Lock entries live in the enqueue server's memory, not a transparent table, so there is no
        # RFC_READ_TABLE fallback. This check needs ENQUEUE_READ to be remote-enabled / authorized.
        $r.Fallback = "None (locks are not table-readable)"
        $r.FallbackResult = "Requires ENQUEUE_READ (RFC-enabled)"
        $r.Status = "SKIPPED"
    }
    return $r
}

# ---- SM13 : update records (informational) ----
function Test-Updates {
    param($Dest)
    $r = New-CheckResult "SM13" "Update Records"
    $r.Threshold = "informational only"
    $r.Primary = "RFC_READ_TABLE on VBMOD"
    try {
        # Trim to key fields: reading all columns can exceed the 512-byte RFC_READ_TABLE row buffer.
        $fn = $Dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn.SetValue("QUERY_TABLE", "VBMOD")
        $fn.SetValue("DELIMITER", "|")
        $fields = $fn.GetTable("FIELDS")
        foreach ($f in @("VBKEY", "VBMODCNT")) { Add-TableRow $fields "FIELDNAME" $f }
        $fn.Invoke($Dest)
        $count = $fn.GetTable("DATA").RowCount
        $r.PrimaryResult = "$count update records"
    } catch {
        $r.PrimaryResult = "Not available"; $r.Fallback = "Not available"; $r.Status = "SKIPPED"
    }
    return $r
}

# ---- SMQ1 : qRFC outbound queue ----
function Test-Queues {
    param($Dest)
    $r = New-CheckResult "SMQ1" "qRFC Queue Status"
    $r.Threshold = "informational only"
    $r.Primary = "TRFC_QOUT_GET_STATUS"
    try {
        $null = Invoke-Rfc $Dest "TRFC_QOUT_GET_STATUS" @{}
        $r.PrimaryResult = "Success"
        return $r
    } catch {
        $r.PrimaryResult = "Not available"
        $r.Fallback = "RFC_READ_TABLE on TRFCQOUT"
    }
    try {
        # Trim to key fields: reading all columns can exceed the 512-byte RFC_READ_TABLE row buffer.
        $fn = $Dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn.SetValue("QUERY_TABLE", "TRFCQOUT")
        $fn.SetValue("DELIMITER", "|")
        $fields = $fn.GetTable("FIELDS")
        foreach ($f in @("QNAME", "QSTATE")) { Add-TableRow $fields "FIELDNAME" $f }
        $fn.Invoke($Dest)
        $count = $fn.GetTable("DATA").RowCount
        $r.FallbackResult = "$count qRFC records"
    } catch {
        $r.FallbackResult = "Failed"; $r.Status = "SKIPPED"
    }
    return $r
}

# ---- SM51 : application servers ----
function Test-Servers {
    param($Dest)
    $r = New-CheckResult "SM51" "Application Servers"
    $r.Threshold = ">= 1 required"
    $r.Primary = "TH_SERVER_LIST"
    try {
        $fn = Invoke-Rfc $Dest "TH_SERVER_LIST" @{}
        $count = $fn.GetTable("LIST").RowCount
        $r.PrimaryResult = "$count active servers"
        if ($count -lt 1) { $r.Status = "CRITICAL"; $r.Code = $EXIT_CRITICAL }
    } catch {
        $r.PrimaryResult = "Not available"; $r.Fallback = "Not available"; $r.Status = "SKIPPED"
    }
    return $r
}

# ---- SM37 : aborted background jobs in the last 24h ----
function Test-Jobs {
    param($Dest, [string]$User)
    $r = New-CheckResult "SM37" "Background Jobs (Last 24h)"
    $r.Threshold = "> $JOB_WARN = WARNING"
    $fromDate = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
    $toDate   = (Get-Date).ToString("yyyyMMdd")

    # Primary (A): TBTCO with trimmed columns + WHERE STATUS='A' AND date (row count = aborted jobs)
    $r.Primary = "RFC_READ_TABLE on TBTCO (STATUS='A')"
    try {
        $fn = $Dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn.SetValue("QUERY_TABLE", "TBTCO")
        $fn.SetValue("DELIMITER", "|")
        $fields = $fn.GetTable("FIELDS")
        foreach ($f in @("JOBNAME", "STATUS", "SDLSTRTDT", "ENDDATE")) { Add-TableRow $fields "FIELDNAME" $f }
        $options = $fn.GetTable("OPTIONS")
        Add-TableRow $options "TEXT" "STATUS = 'A'"
        Add-TableRow $options "TEXT" "AND SDLSTRTDT >= '$fromDate'"
        $fn.Invoke($Dest)
        $aborted = $fn.GetTable("DATA").RowCount
        $r.PrimaryResult = "$aborted aborted jobs (since $fromDate)"
        if ($aborted -gt $JOB_WARN) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
        return $r
    } catch {
        $r.PrimaryResult = "Not available"
        $r.Fallback = "XBP BAPI_XBP_JOB_SELECT"
    }

    # Fallback (B): XBP over a stateful XMI session
    try {
        [void][SAP.Middleware.Connector.RfcSessionManager]::BeginContext($Dest)
        try {
            $logon = $Dest.Repository.CreateFunction("BAPI_XMI_LOGON")
            $logon.SetValue("EXTCOMPANY", "HERMES")
            $logon.SetValue("EXTPRODUCT", "SAP_MONITOR")
            $logon.SetValue("INTERFACE", "XBP")
            $logon.SetValue("VERSION", "3.0")
            $logon.Invoke($Dest)

            $sel = $Dest.Repository.CreateFunction("BAPI_XBP_JOB_SELECT")
            $sel.SetValue("EXTERNAL_USER_NAME", $User)
            $p = $sel.GetStructure("JOB_SELECT_PARAM")
            $p.SetValue("JOBNAME", "*")
            $p.SetValue("USERNAME", "*")
            $p.SetValue("FROM_DATE", $fromDate)
            $p.SetValue("TO_DATE", $toDate)
            $p.SetValue("ABORTED", "X")
            $sel.Invoke($Dest)
            $aborted = $sel.GetTable("JOB_HEAD").RowCount

            try {
                $logoff = $Dest.Repository.CreateFunction("BAPI_XMI_LOGOFF")
                $logoff.SetValue("INTERFACE", "XBP")
                $logoff.Invoke($Dest)
            } catch { }

            $r.FallbackResult = "$aborted aborted jobs (since $fromDate)"
            if ($aborted -gt $JOB_WARN) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
        } finally {
            [void][SAP.Middleware.Connector.RfcSessionManager]::EndContext($Dest)
        }
    } catch {
        $r.FallbackResult = "Failed"; $r.Status = "SKIPPED"
    }
    return $r
}

# ---- ST22 : short dumps ----
function Test-Dumps {
    param($Dest)
    $r = New-CheckResult "ST22" "Short Dumps"
    $r.Threshold = "> $DUMP_WARN = WARNING, > $DUMP_CRIT = CRITICAL"
    $r.Primary = "/SDF/GET_DUMP_LOG"

    # Primary: /SDF/GET_DUMP_LOG (recent dumps; dynamic field dump)
    try {
        $fn = Invoke-Rfc $Dest "/SDF/GET_DUMP_LOG" @{}
        $dumpTable = $null
        foreach ($tn in @("ET_E2E_LOG", "ET_DUMPS", "DUMP_LIST", "IT_DUMPS")) {
            try { $dumpTable = $fn.GetTable($tn); if ($null -ne $dumpTable) { break } } catch { }
        }
        if ($null -ne $dumpTable -and $dumpTable.RowCount -gt 0) {
            $rows = $dumpTable.RowCount
            $r.PrimaryResult = "$rows dumps found"
            if ($rows -gt $DUMP_CRIT) { $r.Status = "CRITICAL"; $r.Code = $EXIT_CRITICAL }
            elseif ($rows -gt $DUMP_WARN) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
            # dynamic field dump (best effort)
            try {
                $lineMeta = $dumpTable.Metadata.LineType
                $max = [Math]::Min($rows, 10)
                for ($i = 0; $i -lt $max; $i++) {
                    $dumpTable.CurrentIndex = $i
                    $parts = @()
                    for ($f = 0; $f -lt $lineMeta.FieldCount; $f++) {
                        $name = $lineMeta[$f].Name
                        $val = ""
                        try { $val = $dumpTable.GetString($name) } catch { }
                        $parts += "$name=$val"
                    }
                    $r.Detail += ($parts -join " | ")
                }
                if ($rows -gt 10) { $r.Detail += "... ($($rows - 10) more)" }
            } catch { }
            return $r
        } else {
            $r.PrimaryResult = "No dumps returned"
            return $r
        }
    } catch {
        $r.PrimaryResult = "Not available"
        $r.Fallback = "RFC_READ_TABLE on SNAP (last 24h, distinct dumps)"
    }

    # Fallback: SNAP key fields, 24h window, distinct dumps (avoids 512-byte buffer overflow)
    try {
        $fromDate = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
        $fn = $Dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn.SetValue("QUERY_TABLE", "SNAP")
        $fn.SetValue("DELIMITER", "|")
        $fields = $fn.GetTable("FIELDS")
        foreach ($f in @("DATUM", "UZEIT", "AHOST", "UNAME")) { Add-TableRow $fields "FIELDNAME" $f }
        $options = $fn.GetTable("OPTIONS")
        Add-TableRow $options "TEXT" "DATUM >= '$fromDate'"
        $fn.Invoke($Dest)
        $data = $fn.GetTable("DATA")
        $dumps = New-Object System.Collections.Generic.HashSet[string]
        for ($i = 0; $i -lt $data.RowCount; $i++) {
            $data.CurrentIndex = $i
            [void]$dumps.Add($data.GetString("WA"))
        }
        $count = $dumps.Count
        $r.FallbackResult = "$count dumps (since $fromDate)"
        if ($count -gt $DUMP_CRIT) { $r.Status = "CRITICAL"; $r.Code = $EXIT_CRITICAL }
        elseif ($count -gt $DUMP_WARN) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
    } catch {
        $r.FallbackResult = "Failed"; $r.Status = "SKIPPED"
    }
    return $r
}

# SMLG helper: most recent day (within lookback) with DIALOG ('01') workload for a server;
# returns @{ AvgMs; DaysAgo } or $null.
function Get-DialogAvgMs {
    param($Dest, [string]$Sid, [string]$Server)
    for ($d = 0; $d -le $RESPTIME_LOOKBACK_DAYS; $d++) {
        try {
            $day = (Get-Date).AddDays(-$d).ToString("yyyyMMdd")
            $fn = Invoke-Rfc $Dest "SWNC_COLLECTOR_GET_AGGREGATES" @{
                COMPONENT = $Server; ASSIGNDSYS = $Sid; PERIODTYPE = "D"; PERIODSTRT = $day; SUMMARY_ONLY = "X"
            }
            $tt = $fn.GetTable("TASKTYPE")
            for ($i = 0; $i -lt $tt.RowCount; $i++) {
                $tt.CurrentIndex = $i
                if ($tt.GetString("TASKTYPE") -eq "01") {
                    $count = $tt.GetLong("COUNT")
                    if ($count -gt 0) { return @{ AvgMs = ($tt.GetDouble("RESPTI") / $count); DaysAgo = $d } }
                }
            }
        } catch { }
    }
    return $null
}

# ---- SMLG : per-app-server dialog response time ----
function Test-ResponseTimes {
    param($Dest, [string]$Sid)
    $r = New-CheckResult "SMLG" "Logon Group Response Times"
    $r.Threshold = "> $RESPTIME_WARN_MS ms = WARNING"
    $r.Primary = "SWNC_COLLECTOR_GET_AGGREGATES (DIALOG, per app server)"
    try {
        $fn = Invoke-Rfc $Dest "TH_SERVER_LIST" @{}
        $servers = $fn.GetTable("LIST")
        $total = $servers.RowCount
        $measured = 0
        for ($s = 0; $s -lt $total; $s++) {
            $servers.CurrentIndex = $s
            $server = $servers.GetString("NAME")
            $res = Get-DialogAvgMs $Dest $Sid $server
            if ($null -eq $res) {
                $r.Detail += ("{0} : no dialog workload data (last {1} days)" -f $server, $RESPTIME_LOOKBACK_DAYS)
                continue
            }
            $measured++
            $st = if ($res.AvgMs -gt $RESPTIME_WARN_MS) { "WARNING" } else { "OK" }
            if ($st -eq "WARNING" -and $r.Code -lt $EXIT_WARNING) { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
            $r.Detail += ("{0} : {1:N0} ms  (DIALOG, {2} day(s) ago)  -> {3}" -f $server, $res.AvgMs, $res.DaysAgo, $st)
        }
        $r.PrimaryResult = "$measured of $total server(s) had dialog data"
        return $r
    } catch {
        $r.PrimaryResult = "Not available"
        $r.Fallback = "SWNC on connected instance (RFC_GET_SYSTEM_INFO)"
    }

    # Fallback: TH_SERVER_LIST is unavailable, so measure only the instance we're connected to.
    # RFC_GET_SYSTEM_INFO is a basic RFC-enabled FM and also yields the SID, avoiding the blank-attr case.
    try {
        $si = Invoke-Rfc $Dest "RFC_GET_SYSTEM_INFO" @{}
        $rfcsi  = $si.GetStructure("RFCSI_EXPORT")
        $server = $rfcsi.GetString("RFCDEST")
        $sysid  = if ($rfcsi.GetString("RFCSYSID")) { $rfcsi.GetString("RFCSYSID") } else { $Sid }
        $res = Get-DialogAvgMs $Dest $sysid $server
        if ($null -eq $res) {
            $r.FallbackResult = "no dialog workload data (last $RESPTIME_LOOKBACK_DAYS days)"
            $r.Status = "SKIPPED"
        } else {
            $st = if ($res.AvgMs -gt $RESPTIME_WARN_MS) { "WARNING" } else { "OK" }
            if ($st -eq "WARNING") { $r.Status = "WARNING"; $r.Code = $EXIT_WARNING }
            $r.FallbackResult = "1 server measured (connected instance)"
            $r.Detail += ("{0} : {1:N0} ms  (DIALOG, {2} day(s) ago)  -> {3}" -f $server, $res.AvgMs, $res.DaysAgo, $st)
        }
    } catch {
        $r.FallbackResult = "Failed"; $r.Status = "SKIPPED"
    }
    return $r
}

# ============================================================
# Output renderers
# ============================================================

function Write-TextReport {
    param($Info, $Results, [int]$Overall)
    Write-Output "=============================================================="
    Write-Output ("  SAP System Monitor v{0}" -f $Info.Version)
    Write-Output ("  Run Date     : {0}" -f $Info.RunDate)
    Write-Output ("  Destination  : {0}" -f $Info.Destination)
    Write-Output ("  ASHOST       : {0}" -f $Info.Ashost)
    Write-Output ("  SYSID        : {0}" -f $Info.Sysid)
    Write-Output ("  Client       : {0}" -f $Info.Client)
    Write-Output ("  User         : {0}" -f $Info.User)
    Write-Output "=============================================================="
    Write-Output ""
    foreach ($c in $Results) {
        Write-Output (">>> [{0}] {1}" -f $c.Tx, $c.Name)
        Write-Output ("    Primary Method         : {0}" -f $c.Primary)
        Write-Output ("    Primary Method Result  : {0}" -f $c.PrimaryResult)
        Write-Output ("    Fallback Method        : {0}" -f $c.Fallback)
        Write-Output ("    Fallback Method Result : {0}" -f $c.FallbackResult)
        Write-Output ("    Threshold              : {0}" -f $c.Threshold)
        Write-Output ("    Status                 : {0}" -f $c.Status)
        if ($c.Detail.Count -gt 0) {
            Write-Output "    --------------------------------------------------"
            foreach ($line in $c.Detail) { Write-Output ("      {0}" -f $line) }
            Write-Output "    --------------------------------------------------"
        }
        Write-Output ""
    }
    Write-Output "=============================================================="
    Write-Output ("  OVERALL STATUS : {0}" -f (Get-StatusText $Overall))
    Write-Output "=============================================================="
}

function Write-MarkdownReport {
    param($Info, $Results, [int]$Overall)
    Write-Output ("# SAP System Monitor - {0}" -f $Info.Destination)
    Write-Output ""
    Write-Output ("- **Version:** {0}" -f $Info.Version)
    Write-Output ("- **Run Date:** {0}" -f $Info.RunDate)
    Write-Output ("- **System:** {0} (client {1}) as {2}" -f $Info.Sysid, $Info.Client, $Info.User)
    Write-Output ("- **Host:** {0}" -f $Info.Ashost)
    Write-Output ("- **Overall Status:** {0}" -f (Get-StatusText $Overall))
    Write-Output ""
    Write-Output "| Tx | Check | Result | Threshold | Status |"
    Write-Output "|----|-------|--------|-----------|--------|"
    foreach ($c in $Results) {
        $res = if ($c.FallbackResult -ne "-") { "$($c.PrimaryResult) / fb: $($c.FallbackResult)" } else { $c.PrimaryResult }
        Write-Output ("| {0} | {1} | {2} | {3} | {4} |" -f $c.Tx, $c.Name, $res, $c.Threshold, $c.Status)
    }
    $details = $Results | Where-Object { $_.Detail.Count -gt 0 }
    if ($details) {
        Write-Output ""
        Write-Output "## Details"
        foreach ($c in $details) {
            Write-Output ""
            Write-Output ("### {0} {1}" -f $c.Tx, $c.Name)
            Write-Output '```'
            foreach ($line in $c.Detail) { Write-Output $line }
            Write-Output '```'
        }
    }
}

function Write-JsonReport {
    param($Info, $Results, [int]$Overall)
    [PSCustomObject]@{
        version       = $Info.Version
        runDate       = $Info.RunDate
        destination   = $Info.Destination
        ashost        = $Info.Ashost
        sysid         = $Info.Sysid
        client        = $Info.Client
        user          = $Info.User
        overallStatus = (Get-StatusText $Overall)
        overallCode   = $Overall
        checks        = $Results
    } | ConvertTo-Json -Depth 6
}

# ============================================================
# Main
# ============================================================

# Load NCo assemblies
try {
    Add-Type -Path (Join-Path $NcoPath "sapnco.dll")
    Add-Type -Path (Join-Path $NcoPath "sapnco_utils.dll")
} catch {
    [Console]::Error.WriteLine("[ERROR] Could not load NCo assemblies from '$NcoPath': $_")
    exit $EXIT_CRITICAL
}

# Resolve destination config
$config = Get-DestinationConfig -Name $Destination
if ($config.Count -eq 0) {
    [Console]::Error.WriteLine("[ERROR] Destination '$Destination' not found (looked for $Destination.ncoDestination and sapnco.ini section)")
    exit $EXIT_CRITICAL
}

# Build connection
try {
    $params = New-Object SAP.Middleware.Connector.RfcConfigParameters
    $params.Add("NAME", $Destination)
    $params.Add("ASHOST", $config.ASHOST)
    $params.Add("SYSNR", $config.SYSNR)
    $params.Add("CLIENT", $config.CLIENT)
    $params.Add("USER", $config.USER)
    $params.Add("PASSWD", $config.PASSWD)
    if ($config.ContainsKey("LANG"))      { $params.Add("LANG", $config.LANG) }
    if ($config.ContainsKey("SAPROUTER")) { $params.Add("SAPROUTER", $config.SAPROUTER) }
    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
    $attr = $dest.Attributes
} catch {
    [Console]::Error.WriteLine("[ERROR] Connection to '$Destination' failed: $_")
    exit $EXIT_CRITICAL
}

# Prefer the live connection attributes, but fall back to the destination config when NCo
# returns blank attributes (otherwise SYSID/Client/User render empty and feed empty params downstream).
$info = [PSCustomObject]@{
    Version     = $VERSION
    RunDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Destination = $Destination
    Ashost      = $config.ASHOST
    Sysid       = (Get-FirstNonEmpty $attr.SystemID $config.SYSID)
    Client      = (Get-FirstNonEmpty $attr.Client $config.CLIENT)
    User        = (Get-FirstNonEmpty $attr.User $config.USER)
}

# Run checks (graceful: a thrown check degrades to SKIPPED, never aborts the run)
$results = @(
    Test-Locks         $dest $info.Client
    Test-Updates       $dest
    Test-Queues        $dest
    Test-Servers       $dest
    Test-Jobs          $dest $info.User
    Test-Dumps         $dest
    Test-ResponseTimes $dest $info.Sysid
)

$overall = ($results | Measure-Object -Property Code -Maximum).Maximum
if ($null -eq $overall) { $overall = $EXIT_OK }

switch ($OutputFormat) {
    "Markdown" { Write-MarkdownReport $info $results $overall }
    "Json"     { Write-JsonReport     $info $results $overall }
    default    { Write-TextReport     $info $results $overall }
}

exit $overall
