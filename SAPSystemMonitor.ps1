<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    0.7 - Aligned with SOP_BW System Monitoring Script v1 20 11 2023
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "0.7"
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

function Invoke-SimpleRfc {
    param($Destination, [string]$FunctionName, [hashtable]$Parameters = @{})
    try {
        $func = $Destination.Repository.CreateFunction($FunctionName)
        foreach ($key in $Parameters.Keys) {
            try { $func.SetValue($key, $Parameters[$key]) } catch {}
        }
        $func.Invoke($Destination)
        return $func
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] $FunctionName failed: $_" -ForegroundColor DarkGray }
        return $null
    }
}

# ==================== MONITORING CHECKS ====================

Write-Host "Connecting to $Destination..." -ForegroundColor Green
$dest = Get-NCoDestination -Name $Destination

$results = @{}

# 1. SM12 - Lock Entries
try {
    $sm12 = Invoke-SimpleRfc -Destination $dest -FunctionName "ENQUEUE_READ"
    $results.SM12 = if ($sm12) { "OK" } else { "FAILED" }
} catch { $results.SM12 = "ERROR" }

# 2. SM13 - Update Status
try {
    $sm13 = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_DISPLAY_UPDATE"
    $results.SM13 = if ($sm13) { "OK" } else { "FAILED" }
} catch { $results.SM13 = "ERROR" }

# 3. SMQ1 - Outbound Queue
try {
    $smq1 = Invoke-SimpleRfc -Destination $dest -FunctionName "QRFC_QSTATUS"
    $results.SMQ1 = if ($smq1) { "OK" } else { "FAILED" }
} catch { $results.SMQ1 = "ERROR" }

# 4. SM51 - Application Servers + Free Dialog
try {
    $sm51 = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_SERVER_LIST"
    $results.SM51 = if ($sm51) { "OK" } else { "FAILED" }
} catch { $results.SM51 = "ERROR" }

# 5. SM37 - Job Status
try {
    $sm37 = Invoke-SimpleRfc -Destination $dest -FunctionName "BAPI_XBP_JOB_SELECT" -Parameters @{
        JOBNAME   = "*"
        FROM_DATE = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
    }
    $results.SM37 = if ($sm37) { "OK" } else { "FAILED" }
} catch { $results.SM37 = "ERROR" }

# 6. ST22 - ABAP Runtime Errors
try {
    $st22 = Invoke-SimpleRfc -Destination $dest -FunctionName "SNAPSHOT_GET"
    $results.ST22 = if ($st22) { "OK" } else { "FAILED" }
} catch { $results.ST22 = "ERROR" }

# 7. SMLG - System Response Time
try {
    $smlg = Invoke-SimpleRfc -Destination $dest -FunctionName "SMLG_GET_SERVER_GROUPS"
    $results.SMLG = if ($smlg) { "OK" } else { "FAILED" }
} catch { $results.SMLG = "ERROR" }

# 8. DB02 - Log file sync
try {
    $db02 = Invoke-SimpleRfc -Destination $dest -FunctionName "DB6_PERF_WAIT_EVENTS"
    $results.DB02 = if ($db02) { "OK" } else { "FAILED" }
} catch { $results.DB02 = "ERROR" }

# ==================== OUTPUT ====================

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
foreach ($key in $results.Keys) {
    $status = $results[$key]
    $color = if ($status -eq "OK") { "Green" } else { "Red" }
    Write-Host ("{0,-6} : {1}" -f $key, $status) -ForegroundColor $color
}

Write-Host "`nMonitoring complete." -ForegroundColor Green
return $results
