<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    1.7 - SM13 automated check added
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "1.7"
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

    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($props)
    
    return @{ Destination = $dest; Config = $config }
}

$result = Get-SapDestination -DestName $Destination
$dest   = $result.Destination
$config = $result.Config

# ==================== CONNECTION PROOF ====================
try {
    $ping = $dest.Repository.CreateFunction("RFC_PING")
    $ping.Invoke($dest)
    Write-Host "[OK] Connected successfully to $Destination (Client $($config.CLIENT)) as $($config.USER)" -ForegroundColor Green
} catch {
    Write-Error "Connection test failed: $_"
    exit 1
}

# ==================== SM12 - Lock Entries ====================
function Get-SM12_Locks {
    param($Destination)
    try {
        $func = $Destination.Repository.CreateFunction("ENQUEUE_READ")
        $func.SetValue("GCLIENT", $config.CLIENT)
        $func.SetValue("GUNAME", "*")
        $func.Invoke($Destination)
        $lockTable = $func.GetTableParameterList().GetTable("ENQ")
        return $lockTable
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] SM12 failed: $_" -ForegroundColor DarkGray }
        return $null
    }
}

# ==================== SM13 - Update Status ====================
function Get-SM13_Updates {
    param($Destination)
    try {
        $func = $Destination.Repository.CreateFunction("TH_DISPLAY_UPDATE")
        $func.SetValue("CLIENT", $config.CLIENT)
        $func.Invoke($Destination)
        $updateTable = $func.GetTableParameterList().GetTable("UPDATES")
        return $updateTable
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] SM13 failed: $_" -ForegroundColor DarkGray }
        return $null
    }
}

# ==================== REPORT ====================

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

# SM12
$locks = Get-SM12_Locks -Destination $dest
$lockCount = if ($locks) { $locks.RowCount } else { 0 }
Write-Host ("SM12 - Lock Entries".PadRight(35) + ": $lockCount locks") -ForegroundColor Cyan
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $lockCount locks found") -ForegroundColor DarkGray
Write-Host ""

# SM13 - Automated
$updates = Get-SM13_Updates -Destination $dest
$updateCount = if ($updates) { $updates.RowCount } else { 0 }
Write-Host ("SM13 - Update Status".PadRight(35) + ": $updateCount updates") -ForegroundColor Cyan
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ("   Result    : $updateCount updates found") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM51 - Application Server Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM37 - Job Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
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
