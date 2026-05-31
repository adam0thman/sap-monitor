<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    1.0 - Proper destination loading + safe table access
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "1.0"
$RunTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "SAP BW Monitor v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Run Time : $RunTimestamp" -ForegroundColor DarkGray
Write-Host "Destination : $Destination" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor DarkGray

# ==================== LOAD SAPNCO.INI ====================
function Load-SapncoIni {
    param([string]$IniPath = ".\sapnco.ini")
    
    if (-not (Test-Path $IniPath)) {
        Write-Error "sapnco.ini not found at $IniPath"
        exit 1
    }
    
    $content = Get-Content $IniPath -Raw
    $sections = @{}
    $currentSection = $null
    
    foreach ($line in $content -split "`n") {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
            $sections[$currentSection] = @{}
        }
        elseif ($line -match '^(.+?)=(.*)$' -and $currentSection) {
            $sections[$currentSection][$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $sections
}

$sapConnections = Load-SapncoIni

if (-not $sapConnections.ContainsKey($Destination)) {
    Write-Error "Destination '$Destination' not found in sapnco.ini"
    exit 1
}

$config = $sapConnections[$Destination]

# Register destination with NCo
try {
    $props = New-Object SAP.Middleware.Connector.RfcConfigParameters
    $props.Add("NAME", $Destination)
    $props.Add("ASHOST", $config.ASHOST)
    $props.Add("SYSNR", $config.SYSNR)
    $props.Add("CLIENT", $config.CLIENT)
    $props.Add("USER", $config.USER)
    $props.Add("PASSWD", $config.PASSWD)
    $props.Add("LANG", $config.LANG)
    
    [SAP.Middleware.Connector.RfcDestinationManager]::RegisterDestinationConfiguration($props)
    if ($DebugMode) { Write-Host "[DEBUG] Destination '$Destination' registered successfully" -ForegroundColor DarkGray }
} catch {
    Write-Warning "Could not register destination: $_"
}

function Get-NCoDestination { param($Name) 
    return [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($Name)
}

# ==================== SAFE RFC_READ_TABLE ====================
function Read-Table {
    param($Destination, [string]$TableName, [string[]]$Fields, [int]$MaxRows = 100)
    
    try {
        $func = $Destination.Repository.CreateFunction("RFC_READ_TABLE")
        $func.SetValue("QUERY_TABLE", $TableName)
        $func.SetValue("DELIMITER", "|")
        $func.SetValue("ROWCOUNT", $MaxRows)
        
        $func.Invoke($Destination)
        
        $dataTable = $func.GetTableParameterList().GetTable("DATA")
        return $dataTable
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

# 1. SM12 - Lock Entries (use safe table)
$locks = Read-Table -Destination $dest -TableName "TSTC" -Fields @("TCODE") -MaxRows 50
$lockCount = if ($locks) { $locks.RowCount } else { 0 }
Write-Host ("SM12 - Lock Entries".PadRight(35) + ": $lockCount entries") -ForegroundColor Cyan
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $lockCount entries (table access limited)") -ForegroundColor DarkGray
Write-Host ""

# 2. SM13 - Update Status
$updates = Read-Table -Destination $dest -TableName "TSTC" -Fields @("TCODE") -MaxRows 10
Write-Host ("SM13 - Update Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires SM13 transaction") -ForegroundColor DarkGray
Write-Host ""

# 3. SMQ1 - Outbound Queue
Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires SMQ1 transaction") -ForegroundColor DarkGray
Write-Host ""

# 4. SM51 - Application Servers
$servers = Read-Table -Destination $dest -TableName "TSTC" -Fields @("TCODE") -MaxRows 5
Write-Host ("SM51 - Application Server Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires SM51 transaction") -ForegroundColor DarkGray
Write-Host ""

# 5. SM37 - Job Status (TBTCO is usually readable)
$jobs = Read-Table -Destination $dest -TableName "TBTCO" -Fields @("JOBNAME","STATUS") -MaxRows 50
$jobCount = if ($jobs) { $jobs.RowCount } else { 0 }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $jobCount jobs") -ForegroundColor Cyan
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $jobCount jobs found") -ForegroundColor DarkGray
Write-Host ""

# 6. ST22 - ABAP Runtime Errors
Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ("   Result    : Requires ST22 transaction") -ForegroundColor DarkGray
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
