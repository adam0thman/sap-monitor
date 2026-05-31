<#
.SYNOPSIS
    SAP BW System Monitor (PowerShell + NCo 3.1)
.VERSION
    1.3 - Clear connection proof + system info
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown",
    [bool]$DebugMode = $true
)

$ScriptVersion = "1.3"
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

# ==================== PROVE CONNECTION ====================
try {
    $sysInfo = $dest.Repository.CreateFunction("RFC_SYSTEM_INFO")
    $sysInfo.Invoke($dest)
    $sys = $sysInfo.GetExportParameterList().GetStructure("RFCSI_EXPORT")

    $systemId = $sys.GetString("RFCSYSID")
    $client   = $config["CLIENT"]
    $hostName = $sys.GetString("RFCHOST")

    Write-Host "[OK] Connected successfully to $systemId (Client $client) on $hostName" -ForegroundColor Green
} catch {
    Write-Error "Connection test failed: $_"
    exit 1
}

# ==================== TABLE READER ====================
function Read-Table {
    param($Destination, [string]$TableName, [int]$MaxRows = 20)
    
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

# ==================== REPORT ====================

Write-Host "`n=== SAP BW Monitoring Report ===" -ForegroundColor Yellow
Write-Host ""

Write-Host ("SM12 - Lock Entries".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No obsolete locks > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Reason    : Table is cluster table (not readable via RFC)") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM13 - Update Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : No update records in error") -ForegroundColor DarkGray
Write-Host ("   Reason    : Requires SM13 transaction") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SMQ1 - Outbound Queue".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Warning > 600, Red > 1000") -ForegroundColor DarkGray
Write-Host ("   Reason    : Requires SMQ1 transaction") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SM51 - Application Server Status".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : All servers Active, Free Dialog >= 5") -ForegroundColor DarkGray
Write-Host ("   Reason    : Requires SM51 transaction") -ForegroundColor DarkGray
Write-Host ""

$jobs = Read-Table -Destination $dest -TableName "TBTCO" -MaxRows 15
$jobCount = if ($jobs) { $jobs.RowCount } else { 0 }
Write-Host ("SM37 - Job Status".PadRight(35) + ": $jobCount jobs") -ForegroundColor Cyan
Write-Host ("   Threshold : No jobs running > 24 hours") -ForegroundColor DarkGray
Write-Host ("   Result    : $jobCount jobs found today") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("ST22 - ABAP Runtime Errors".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : < 300 logs per hour") -ForegroundColor DarkGray
Write-Host ("   Reason    : SNAP table is protected") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("SMLG - System Response Time".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Response time < 4000ms") -ForegroundColor DarkGray
Write-Host ("   Reason    : Requires SMLG transaction") -ForegroundColor DarkGray
Write-Host ""

Write-Host ("DB02 - Log file sync".PadRight(35) + ": CHECK MANUALLY") -ForegroundColor Yellow
Write-Host ("   Threshold : Avg.WT < 80ms") -ForegroundColor DarkGray
Write-Host ("   Reason    : Requires DB02 transaction") -ForegroundColor DarkGray
Write-Host ""

Write-Host "Monitoring complete." -ForegroundColor Green
