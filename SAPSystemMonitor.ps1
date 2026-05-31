<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    1.4 - Fixed connection test
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "1.4"
$RunTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "SAP BW Monitor v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Run Time : $RunTimestamp" -ForegroundColor DarkGray
Write-Host "Destination : $Destination" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor DarkGray

# ==================== LOAD FROM sapnco.ini ====================
function Get-SapDestination {
    param([string]$DestName, [string]$IniPath = ".\sapnco.ini")

    if (-not (Test-Path $IniPath)) {
        Write-Error "sapnco.ini not found"
        exit 1
    }

    $lines = Get-Content $IniPath
    $currentSection = $null
    $config = @{}

    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
        }
        elseif ($line -match '^(.+?)=(.*)$' -and $currentSection -eq $DestName) {
            $config[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    if ($config.Count -eq 0) {
        Write-Error "Destination '$DestName' not found in sapnco.ini"
        exit 1
    }

    $props = New-Object SAP.Middleware.Connector.RfcConfigParameters
    $props["NAME"]   = $DestName
    $props["ASHOST"] = $config["ASHOST"]
    $props["SYSNR"]  = $config["SYSNR"]
    $props["CLIENT"] = $config["CLIENT"]
    $props["USER"]   = $config["USER"]
    $props["PASSWD"] = $config["PASSWD"]
    $props["LANG"]   = $config["LANG"]

    return [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($props)
}

$dest = Get-SapDestination -DestName $Destination

# ==================== SIMPLE CONNECTION PROOF ====================
try {
    $ping = $dest.Repository.CreateFunction("RFC_PING")
    $ping.Invoke($dest)
    Write-Host "[OK] Connected successfully to $Destination (Client $($config.CLIENT))" -ForegroundColor Green
} catch {
    Write-Error "Connection test failed: $_"
    exit 1
}

# ==================== REPORT ====================

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

Write-Host ("SM12 - Lock Entries".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM13 - Update Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM51 - Application Server Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ""

$jobs = Read-Table -Destination $dest -TableName "TBTCO" -MaxRows 15
$jobCount = if ($jobs) { $jobs.RowCount } else { 0 }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $jobCount jobs") -ForegroundColor Cyan
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $jobCount jobs found") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SMLG - System Response Time".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Response time < 4000ms") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("DB02 - Log file sync".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Avg.WT < 80ms") -ForegroundColor DarkGray
Write-Host ""

Write-Host "Monitoring complete." -ForegroundColor Green
