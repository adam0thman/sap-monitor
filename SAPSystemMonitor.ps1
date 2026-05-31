<#
.SYNOPSIS
    SAP System Monitor using NCo 3.1 (PowerShell)
.VERSION
    0.4
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,

    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",

    [bool]$DebugMode = $true
)

$ScriptVersion = "0.4"
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

function Read-Table {
    param($Destination, [string]$Table, [string[]]$Fields, [string]$Where = "")
    
    $func = $Destination.Repository.CreateFunction("RFC_READ_TABLE")
    $func.SetValue("QUERY_TABLE", $Table)
    $func.SetValue("DELIMITER", "|")
    
    $paramList = $null
    try {
        $paramList = $func.GetTableParameterList()
    } catch {
        if ($DebugMode) { Write-Host "[DEBUG] GetTableParameterList() not available" -ForegroundColor DarkGray }
        return $null
    }
    
    if ($Fields -and $paramList) {
        $fieldTable = $paramList.GetTable("FIELDS")
        foreach ($f in $Fields) {
            $row = $fieldTable.Append()
            $row.SetValue("FIELDNAME", $f)
        }
    }
    
    if ($Where -and $paramList) {
        $optTable = $paramList.GetTable("OPTIONS")
        $row = $optTable.Append()
        $row.SetValue("TEXT", $Where)
    }
    
    $func.Invoke($Destination)
    
    if ($paramList) {
        return $paramList.GetTable("DATA")
    }
    return $null
}

# ==================== MONITORING ====================

Write-Host "Connecting to $Destination..." -ForegroundColor Green
$dest = Get-NCoDestination -Name $Destination

Write-Host "`n=== SAP Monitoring Checks ===" -ForegroundColor Yellow

try {
    $locks = Read-Table -Destination $dest -Table "ENQ" -Fields @("GUNAME","GCLIENT","GTABNAME") -Where "GUNAME <> ''"
    if ($locks) { Write-Host "SM12 Locks: $($locks.RowCount)" -ForegroundColor Cyan }
} catch { Write-Warning "SM12 failed: $_" }

try {
    $updates = Read-Table -Destination $dest -Table "VBHDR" -Fields @("VBKEY","VBTYP","STATUS") -Where "STATUS = 'I'"
    if ($updates) { Write-Host "SM13 Pending Updates: $($updates.RowCount)" -ForegroundColor Cyan }
} catch { Write-Warning "SM13 failed: $_" }

try {
    $queues = Read-Table -Destination $dest -Table "TRFCQOUT" -Fields @("QNAME","QSTATE") 
    if ($queues) { Write-Host "SMQ1 Queues: $($queues.RowCount)" -ForegroundColor Cyan }
} catch { Write-Warning "SMQ1 failed: $_" }

try {
    $servers = Read-Table -Destination $dest -Table "T000" -Fields @("MANDT","MTEXT") 
    if ($servers) { Write-Host "SM51 Servers check done" -ForegroundColor Cyan }
} catch { Write-Warning "SM51 failed: $_" }

try {
    $jobs = Read-Table -Destination $dest -Table "TBTCO" -Fields @("JOBNAME","STATUS","SDLSTRTDT") -Where "SDLSTRTDT >= '$(Get-Date -Format yyyyMMdd)'"
    if ($jobs) { Write-Host "SM37 Jobs today: $($jobs.RowCount)" -ForegroundColor Cyan }
} catch { Write-Warning "SM37 failed: $_" }

Write-Host "`nMonitoring complete." -ForegroundColor Green
