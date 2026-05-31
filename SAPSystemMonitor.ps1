<#
.SYNOPSIS
    SAP BW / S/4HANA System Monitor using SAP .NET Connector (NCo) 3.1
.VERSION
    1.8
.AUTHOR
    Hermes Agent (corrected NCo 3.1 patterns)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination
)

$ErrorActionPreference = "Stop"
$scriptVersion = "1.8"

# ============================================================
# Load SAP NCo 3.1 DLLs (robust loading)
# ============================================================
$ncoPath = "D:\bwMonitoring"   # <-- CHANGE THIS TO YOUR ACTUAL NCo FOLDER
Add-Type -Path "$ncoPath\sapnco.dll"
Add-Type -Path "$ncoPath\sapnco_utils.dll"

# ============================================================
# Destination loading (INI-style .ncoDestination file supported)
# ============================================================
$ncoFile = "$ncoPath\$Destination.ncoDestination"
if (-not (Test-Path $ncoFile)) {
    Write-Host "Destination file not found: $ncoFile" -ForegroundColor Red
    exit 1
}

$config = @{}
Get-Content $ncoFile | ForEach-Object {
    if ($_ -match '^\[(.+)\]$') { $section = $matches[1] }
    elseif ($_ -match '^(.+?)=(.*)$' -and $section -eq $Destination) {
        $config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

$params = New-Object SAP.Middleware.Connector.RfcConfigParameters
$params.Add("NAME", $Destination)
$params.Add("ASHOST", $config.ASHOST)
$params.Add("SYSNR", $config.SYSNR)
$params.Add("CLIENT", $config.CLIENT)
$params.Add("USER", $config.USER)
$params.Add("PASSWD", $config.PASSWD)
$params.Add("LANG", "EN")

try {
    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
    Write-Host "[OK] Connected successfully to $Destination (Client $($config.CLIENT)) as $($config.USER)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Connection failed: $_" -ForegroundColor Red
    exit 1
}

# ============================================================
# Safe RFC Invocation Helper (NCo 3.1 compatible)
# ============================================================
function Invoke-RfcFunction {
    param(
        $Destination,
        [string]$FunctionName,
        [hashtable]$Parameters = @{},
        [string[]]$TableNames = @()
    )

    try {
        $func = $Destination.Repository.CreateFunction($FunctionName)
    } catch {
        Write-Host "[DEBUG] $FunctionName not available on this system" -ForegroundColor DarkYellow
        return $null
    }

    foreach ($key in $Parameters.Keys) {
        try { $func.SetValue($key, $Parameters[$key]) } catch {}
    }

    try {
        $func.Invoke($Destination)
    } catch {
        Write-Host "[DEBUG] Invoke failed for $FunctionName : $_" -ForegroundColor DarkYellow
        return $null
    }

    $tables = @{}
    foreach ($t in $TableNames) {
        try {
            $tbl = $func.GetTable($t)
            if ($tbl) { $tables[$t] = $tbl }
        } catch {}
    }

    return @{ Function = $func; Tables = $tables }
}

# ============================================================
# Monitoring Report Header
# ============================================================
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "========================================"
Write-Host "SAP BW Monitor v$scriptVersion"
Write-Host "Run Time : $now"
Write-Host "Destination : $Destination"
Write-Host "========================================"

# ============================================================
# SM12 - Lock Entries (ENQUEUE_READ)
# ============================================================
Write-Host "`nSM12 - Lock Entries" -NoNewline
$result = Invoke-RfcFunction -Destination $dest `
    -FunctionName "ENQUEUE_READ" `
    -Parameters @{ GCLIENT = $config.CLIENT } `
    -TableNames @("ENQ")

if ($result -and $result.Tables.ContainsKey("ENQ")) {
    $count = $result.Tables["ENQ"].Count
    Write-Host "                : $count locks"
    if ($count -gt 0) {
        Write-Host "   Threshold : No obsolete locks > 24 hours"
        Write-Host "   Result    : $count locks found"
    }
} else {
    Write-Host "                : CHECK MANUALLY"
}

# ============================================================
# SM13 - Update Status (safe fallback)
# ============================================================
Write-Host "SM13 - Update Status" -NoNewline
# TH_DISPLAY_UPDATE does not exist on many systems.
# Using a safe placeholder until a reliable alternative is implemented.
Write-Host "               : CHECK MANUALLY (TH_DISPLAY_UPDATE not available on TBL)"

# ============================================================
# SMQ1 - Outbound Queue (QRFC_QSTATUS)
# ============================================================
Write-Host "SMQ1 - Outbound Queue" -NoNewline
$qResult = Invoke-RfcFunction -Destination $dest `
    -FunctionName "QRFC_QSTATUS" `
    -TableNames @("QSTATUS")

if ($qResult -and $qResult.Tables.ContainsKey("QSTATUS")) {
    $qCount = $qResult.Tables["QSTATUS"].Count
    Write-Host "              : $qCount entries"
} else {
    Write-Host "              : CHECK MANUALLY"
}
Write-Host "   Threshold : Warning > 600, Red > 1000"

# ============================================================
# SM51 - Application Server Status (TH_SERVER_LIST)
# ============================================================
Write-Host "SM51 - Application Server Status" -NoNewline
$sResult = Invoke-RfcFunction -Destination $dest `
    -FunctionName "TH_SERVER_LIST" `
    -TableNames @("SERVER_LIST")

if ($sResult -and $sResult.Tables.ContainsKey("SERVER_LIST")) {
    $serverCount = $sResult.Tables["SERVER_LIST"].Count
    Write-Host "   : $serverCount servers"
} else {
    Write-Host "   : CHECK MANUALLY"
}
Write-Host "   Threshold : All servers Active, Free Dialog >= 5"

# ============================================================
# SM37 - Job Status (BP_JOB_SELECT)
# ============================================================
Write-Host "SM37 - Job Status" -NoNewline
$jResult = Invoke-RfcFunction -Destination $dest `
    -FunctionName "BP_JOB_SELECT" `
    -Parameters @{ JOBNAME = "*" } `
    -TableNames @("JOBLIST")

if ($jResult -and $jResult.Tables.ContainsKey("JOBLIST")) {
    $jobCount = $jResult.Tables["JOBLIST"].Count
    Write-Host "                : $jobCount jobs"
} else {
    Write-Host "                : CHECK MANUALLY"
}
Write-Host "   Threshold : No jobs running > 24 hours"

# ============================================================
# ST22 / SMLG / DB02 - still require implementation
# ============================================================
Write-Host "ST22 - ABAP Runtime Errors         : CHECK MANUALLY"
Write-Host "   Threshold : < 300 logs per hour"

Write-Host "SMLG - System Response Time        : CHECK MANUALLY"
Write-Host "   Threshold : Response time < 4000ms"

Write-Host "DB02 - Log file sync               : CHECK MANUALLY"
Write-Host "   Threshold : Avg.WT < 80ms"

Write-Host "`nMonitoring complete."
Write-Host "========================================"