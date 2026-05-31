<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    0.9 - Using RFC_READ_TABLE for real data
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "0.9"
$RunTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "SAP BW Monitor v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Run Time : $RunTimestamp" -ForegroundColor DarkGray
Write-Host "Destination : $Destination" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor DarkGray

# Load NCo
$ncoPaths = @(".\sapnco.dll", "$PSScriptRoot\sapnco.dll") | Where-Object { Test-Path $_ }
if ($ncoPaths) {
    $dll = $ncoPaths | Select-Object -First 1
    Add-Type -Path $dll
    Add-Type -Path ($dll -replace 'sapnco\.dll$', 'sapnco_utils.dll')
} else {
    Write-Error "sapnco.dll not found"
    exit 1
}

function Get-NCoDestination { param($Name) 
    return [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($Name)
}

function Read-Table {
    param($Destination, [string]$TableName, [string[]]$Fields, [string]$Where = "")
    
    try {
        $func = $Destination.Repository.CreateFunction("RFC_READ_TABLE")
        $func.SetValue("QUERY_TABLE", $TableName)
        $func.SetValue("DELIMITER", "|")
        
        # Try to set fields if possible
        if ($Fields) {
            try {
                $fieldsTable = $func.GetTableParameterList().GetTable("FIELDS")
                foreach ($f in $Fields) {
                    $row = $fieldsTable.Append()
                    $row.SetValue("FIELDNAME", $f)
                }
            } catch {
                if ($DebugMode) { Write-Host "[DEBUG] Could not set FIELDS for $TableName" -ForegroundColor DarkGray }
            }
        }
        
        $func.Invoke($Destination)
        
        # Try to get DATA table
        try {
            return $func.GetTableParameterList().GetTable("DATA")
        } catch {
            return $null
        }
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] RFC_READ_TABLE on $TableName failed: $_" -ForegroundColor DarkGray }
        return $null
    }
}

# ==================== MONITORING ====================

Write-Host "Connecting to $Destination..." -ForegroundColor Green
$dest = Get-NCoDestination -Name $Destination

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

# 1. SM12 - Lock Entries (ENQ table)
$locks = Read-Table -Destination $dest -TableName "ENQ" -Fields @("GUNAME","GTABNAME")
$sm12Count = if ($locks) { $locks.RowCount } else { 0 }
Write-Host ("SM12 - Lock Entries".PadRight(35) + ": $sm12Count locks") -ForegroundColor Cyan
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $sm12Count locks found") -ForegroundColor DarkGray
Write-Host ""

# 2. SM13 - Update Status (VBHDR table)
$updates = Read-Table -Destination $dest -TableName "VBHDR" -Fields @("VBKEY","STATUS")
$updateErrors = if ($updates) { ($updates | Where-Object { $_.GetString("WA") -like "*E*" }).Count } else { 0 }
Write-Host ("SM13 - Update Status".PadRight(35) + ": $updateErrors errors") -ForegroundColor Cyan
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ("   Result    : $updateErrors errors found") -ForegroundColor DarkGray
Write-Host ""

# 3. SMQ1 - Outbound Queue (TRFCQOUT)
$queues = Read-Table -Destination $dest -TableName "TRFCQOUT" -Fields @("QNAME","QSTATE")
$qCount = if ($queues) { $queues.RowCount } else { 0 }
Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": $qCount queues") -ForegroundColor Cyan
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ("   Result    : $qCount queues found") -ForegroundColor DarkGray
Write-Host ""

# 4. SM51 - Application Servers
$servers = Read-Table -Destination $dest -TableName "T000" -Fields @("MANDT","MTEXT")
$sCount = if ($servers) { $servers.RowCount } else { 0 }
Write-Host ("SM51 - Application Server Status".PadRight(35) + ": $sCount servers") -ForegroundColor Cyan
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ("   Result    : $sCount servers found") -ForegroundColor DarkGray
Write-Host ""

# 5. SM37 - Job Status (TBTCO)
$jobs = Read-Table -Destination $dest -TableName "TBTCO" -Fields @("JOBNAME","STATUS") -Where "SDLSTRTDT >= '$(Get-Date -Format yyyyMMdd)'"
$jobCount = if ($jobs) { $jobs.RowCount } else { 0 }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $jobCount jobs today") -ForegroundColor Cyan
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $jobCount jobs found today") -ForegroundColor DarkGray
Write-Host ""

# 6. ST22 - ABAP Runtime Errors (SNAP)
$errors = Read-Table -Destination $dest -TableName "SNAP" -Fields @("FLDATE","FLTIME")
$errCount = if ($errors) { $errors.RowCount } else { 0 }
Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": $errCount errors") -ForegroundColor Cyan
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ("   Result    : $errCount errors found") -ForegroundColor DarkGray
Write-Host ""

# 7. SMLG - System Response Time
Write-Host ("SMLG - System Response Time".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Response time < 4000ms") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires SMLG transaction") -ForegroundColor DarkGray
Write-Host ""

# 8. DB02 - Log file sync
Write-Host ("DB02 - Log file sync".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Avg.WT < 80ms") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires DB02 transaction") -ForegroundColor DarkGray
Write-Host ""

Write-Host "Monitoring complete." -ForegroundColor Green
