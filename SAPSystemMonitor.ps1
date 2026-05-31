<#
.SYNOPSIS
    SAP System Monitor using NCo 3.1 (PowerShell)
.VERSION
    0.5 - Switched to simpler, more compatible RFCs
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "0.5"
$RunTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "SAP Monitor v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Run Time : $RunTimestamp" -ForegroundColor DarkGray
Write-Host "Destination : $Destination" -ForegroundColor DarkGray
Write-Host "Debug Mode : $DebugMode" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor DarkGray

# Load NCo
$ncoPaths = @(".\sapnco.dll", "$PSScriptRoot\sapnco.dll") | Where-Object { Test-Path $_ }
if ($ncoPaths) {
    $dll = $ncoPaths | Select-Object -First 1
    if ($DebugMode) { Write-Host "[DEBUG] Loading NCo from: $dll" -ForegroundColor DarkGray }
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

Write-Host "`n=== SAP Monitoring Checks (Compatible Mode) ===" -ForegroundColor Yellow

# 1. System Info (very reliable)
try {
    $sysInfo = Invoke-SimpleRfc -Destination $dest -FunctionName "RFC_SYSTEM_INFO"
    if ($sysInfo) {
        $sysId = $sysInfo.GetValue("RFCSI_EXPORT")
        Write-Host "System Info: OK" -ForegroundColor Green
        if ($DebugMode) { Write-Host "[DEBUG] System ID info retrieved" -ForegroundColor DarkGray }
    }
} catch { Write-Warning "RFC_SYSTEM_INFO failed" }

# 2. Server List
try {
    $servers = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_SERVER_LIST"
    if ($servers) {
        Write-Host "SM51 Servers: Available" -ForegroundColor Green
    }
} catch { Write-Warning "TH_SERVER_LIST failed" }

# 3. User List (lightweight)
try {
    $users = Invoke-SimpleRfc -Destination $dest -FunctionName "TH_USER_LIST"
    if ($users) {
        Write-Host "Active Users: Available" -ForegroundColor Green
    }
} catch { Write-Warning "TH_USER_LIST failed" }

# 4. Background Jobs (modern BAPI)
try {
    $jobs = Invoke-SimpleRfc -Destination $dest -FunctionName "BAPI_XBP_JOB_SELECT" -Parameters @{
        JOBNAME   = "*"
        FROM_DATE = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
    }
    if ($jobs) {
        Write-Host "SM37 Jobs: Available" -ForegroundColor Green
    }
} catch { Write-Warning "BAPI_XBP_JOB_SELECT failed" }

Write-Host "`nMonitoring complete." -ForegroundColor Green
