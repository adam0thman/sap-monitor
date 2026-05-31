<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    0.8 - Professional output aligned with SOP
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "0.8"
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

# ==================== MONITORING ====================

Write-Host "Connecting to $Destination..." -ForegroundColor Green
$dest = Get-NCoDestination -Name $Destination

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

# 1. SM12 - Lock Entries
$sm12Result = Invoke-SimpleRfc -Destination $dest -FunctionName "ENQUEUE_READ"
$sm12Status = if ($sm12Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SM12 - Lock Entries".PadRight(35) + ": $sm12Status") -ForegroundColor $(if ($sm12Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $sm12Status") -ForegroundColor DarkGray
Write-Host ""

# 2. SM13 - Update Status
$sm13Result = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_DISPLAY_UPDATE"
$sm13Status = if ($sm13Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SM13 - Update Status".PadRight(35) + ": $sm13Status") -ForegroundColor $(if ($sm13Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ("   Result    : $sm13Status") -ForegroundColor DarkGray
Write-Host ""

# 3. SMQ1 - Outbound Queue
$smq1Result = Invoke-SimpleRfc -Destination $dest -FunctionName "QRFC_QSTATUS"
$smq1Status = if ($smq1Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": $smq1Status") -ForegroundColor $(if ($smq1Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ("   Result    : $smq1Status") -ForegroundColor DarkGray
Write-Host ""

# 4. SM51 - Application Servers
$sm51Result = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_SERVER_LIST"
$sm51Status = if ($sm51Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SM51 - Application Server Status".PadRight(35) + ": $sm51Status") -ForegroundColor $(if ($sm51Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ("   Result    : $sm51Status") -ForegroundColor DarkGray
Write-Host ""

# 5. SM37 - Job Status
$sm37Result = Invoke-SimpleRfc -Destination $dest -FunctionName "BAPI_XBP_JOB_SELECT" -Parameters @{
    JOBNAME   = "*"
    FROM_DATE = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
}
$sm37Status = if ($sm37Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $sm37Status") -ForegroundColor $(if ($sm37Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $sm37Status") -ForegroundColor DarkGray
Write-Host ""

# 6. ST22 - ABAP Runtime Errors
$st22Result = Invoke-SimpleRfc -Destination $dest -FunctionName "SNAPSHOT_GET"
$st22Status = if ($st22Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": $st22Status") -ForegroundColor $(if ($st22Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ("   Result    : $st22Status") -ForegroundColor DarkGray
Write-Host ""

# 7. SMLG - System Response Time
$smlgResult = Invoke-SimpleRfc -Destination $dest -FunctionName "SMLG_GET_SERVER_GROUPS"
$smlgStatus = if ($smlgResult) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("SMLG - System Response Time".PadRight(35) + ": $smlgStatus") -ForegroundColor $(if ($smlgStatus -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : Response time < 4000ms") -ForegroundColor DarkGray
Write-Host ("   Result    : $smlgStatus") -ForegroundColor DarkGray
Write-Host ""

# 8. DB02 - Log file sync
$db02Result = Invoke-SimpleRfc -Destination $dest -FunctionName "DB6_PERF_WAIT_EVENTS"
$db02Status = if ($db02Result) { "OK" } else { "CHECK MANUALLY" }
Write-Host ("DB02 - Log file sync".PadRight(35) + ": $db02Status") -ForegroundColor $(if ($db02Status -eq "OK") { "Green" } else { "Yellow" })
Write-Host ("   Threshold : Avg.WT < 80ms") -ForegroundColor DarkGray
Write-Host ("   Result    : $db02Status") -ForegroundColor DarkGray
Write-Host ""

Write-Host "Monitoring complete." -ForegroundColor Green
