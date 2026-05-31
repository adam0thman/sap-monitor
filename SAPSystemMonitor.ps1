<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    1.1 - Fixed destination loading from sapnco.ini
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "1.1"
$RunTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "SAP BW Monitor v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Run Time : $RunTimestamp" -ForegroundColor DarkGray
Write-Host "Destination : $Destination" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor DarkGray

# ==================== LOAD SAPNCO.INI (Correct Method) ====================
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
            if ($currentSection -eq $DestName) {
                $config = @{}
            }
        }
        elseif ($line -match '^(.+?)=(.*)$' -and $currentSection -eq $DestName) {
            $config[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    if ($config.Count -eq 0) {
        Write-Error "Destination '$DestName' not found in sapnco.ini"
        exit 1
    }

    # Create destination using properties
    $props = New-Object SAP.Middleware.Connector.RfcConfigParameters
    $props["NAME"]     = $DestName
    $props["ASHOST"]   = $config["ASHOST"]
    $props["SYSNR"]    = $config["SYSNR"]
    $props["CLIENT"]   = $config["CLIENT"]
    $props["USER"]     = $config["USER"]
    $props["PASSWD"]   = $config["PASSWD"]
    $props["LANG"]     = $config["LANG"]

    # Register and get destination
    try {
        [SAP.Middleware.Connector.RfcDestinationManager]::RegisterDestinationConfiguration($props)
    } catch {
        # Already registered, ignore
    }

    return [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($DestName)
}

# Get destination
$dest = Get-SapDestination -DestName $Destination

if (-not $dest) {
    Write-Error "Failed to connect to destination '$Destination'"
    exit 1
}

Write-Host "[DEBUG] Successfully connected to $Destination" -ForegroundColor DarkGray

# ==================== SAFE TABLE READER ====================
function Read-Table {
    param($Destination, [string]$TableName, [int]$MaxRows = 50)
    
    try {
        $func = $Destination.Repository.CreateFunction("RFC_READ_TABLE")
        $func.SetValue("QUERY_TABLE", $TableName)
        $func.SetValue("DELIMITER", "|")
        $func.SetValue("ROWCOUNT", $MaxRows)
        
        $func.Invoke($Destination)
        return $func.GetTableParameterList().GetTable("DATA")
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] RFC_READ_TABLE on $TableName failed: $_" -ForegroundColor DarkGray }
        return $null
    }
}

# ==================== MONITORING REPORT ====================

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

# SM12
Write-Host ("SM12 - Lock Entries".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ""

# SM13
Write-Host ("SM13 - Update Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ""

# SMQ1
Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ""

# SM51
Write-Host ("SM51 - Application Server Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ""

# SM37
$jobs = Read-Table -Destination $dest -TableName "TBTCO" -MaxRows 30
$jobCount = if ($jobs) { $jobs.RowCount } else { 0 }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $jobCount jobs") -ForegroundColor Cyan
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $jobCount jobs found") -ForegroundColor DarkGray
Write-Host ""

# ST22
Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ""

# SMLG
Write-Host ("SMLG - System Response Time".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Response time < 4000ms") -ForegroundColor DarkGray
Write-Host ""

# DB02
Write-Host ("DB02 - Log file sync".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Avg.WT < 80ms") -ForegroundColor DarkGray
Write-Host ""

Write-Host "Monitoring complete." -ForegroundColor Green
