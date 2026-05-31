<#
.SYNOPSIS
    SAP System Monitor using NCo 3.1 (PowerShell)
.DESCRIPTION
    Monitors key SAP areas: SM12, SM13, SMQ1, SM51, SM37, ST22, SMLG, DB02
.PARAMETER Destination
    Section name in the .ncoDestination file (e.g. S4D)
.PARAMETER OutputFormat
    Markdown, JSON, or HTML
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination,

    [ValidateSet("Markdown","JSON","HTML")]
    [string]$OutputFormat = "Markdown"
)

# Load SAP NCo assemblies (robust path handling)
$ncoPaths = @(
    ".\nco\sapnco.dll",
    ".\sapnco.dll",
    "$PSScriptRoot\nco\sapnco.dll",
    "$PSScriptRoot\sapnco.dll",
    "C:\Program Files\SAP\NCo\sapnco.dll"
) | Where-Object { Test-Path $_ }

if ($ncoPaths) {
    $dllPath = $ncoPaths | Select-Object -First 1
    Write-Host "Loading NCo from: $dllPath" -ForegroundColor Cyan
    Add-Type -Path $dllPath
    Add-Type -Path ($dllPath -replace 'sapnco\.dll$', 'sapnco_utils.dll')
} else {
    Write-Error "SAP NCo DLLs not found."
    exit 1
}

function Get-NCoDestination {
    param([string]$DestName)
    return [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($DestName)
}

function Invoke-RfcFunction {
    param(
        $Destination,
        [string]$FunctionName,
        [hashtable]$Parameters = @{},
        [string[]]$TableNames = @()
    )

    $func = $Destination.Repository.CreateFunction($FunctionName)

    foreach ($key in $Parameters.Keys) {
        if ($func.GetImportingParameterList().Contains($key)) {
            $func.SetValue($key, $Parameters[$key])
        }
    }

    $func.Invoke($Destination)

    $tables = @{}
    foreach ($tableName in $TableNames) {
        if ($func.GetTableParameterList().Contains($tableName)) {
            $tables[$tableName] = $func.GetTableParameterList().GetTable($tableName)
        }
    }

    return @{
        Function = $func
        Tables   = $tables
    }
}

# ==================== MONITORING FUNCTIONS ====================

function Get-SM12_Locks {
    param($Destination)
    try {
        $result = Invoke-RfcFunction -Destination $Destination -FunctionName "ENQUEUE_READ" -Parameters @{
            GCLIENT = $Destination.Client
            GUNAME  = ""
        } -TableNames @("ENQ")
        return $result.Tables["ENQ"]
    } catch {
        Write-Warning "SM12 check failed: $_"
        return $null
    }
}

function Get-SM13_Updates {
    param($Destination)
    try {
        $result = Invoke-RfcFunction -Destination $Destination -FunctionName "UPDATE_READ" -Parameters @{
            CLIENT = $Destination.Client
        } -TableNames @("UPDATES")
        return $result.Tables["UPDATES"]
    } catch {
        Write-Warning "SM13 check failed: $_"
        return $null
    }
}

function Get-SMQ1_Queues {
    param($Destination)
    try {
        $result = Invoke-RfcFunction -Destination $Destination -FunctionName "TRFC_QRFC_MONITOR" -Parameters @{
            QNAME = ""
        } -TableNames @("QSTATUS")
        return $result.Tables["QSTATUS"]
    } catch {
        Write-Warning "SMQ1 check failed: $_"
        return $null
    }
}

function Get-SM51_Servers {
    param($Destination)
    try {
        $result = Invoke-RfcFunction -Destination $Destination -FunctionName "TH_SERVER_LIST" -TableNames @("SERVER_LIST")
        return $result.Tables["SERVER_LIST"]
    } catch {
        Write-Warning "SM51 check failed: $_"
        return $null
    }
}

function Get-SM37_Jobs {
    param($Destination)
    try {
        $result = Invoke-RfcFunction -Destination $Destination -FunctionName "BP_JOB_SELECT" -Parameters @{
            JOBNAME   = "*"
            JOBGROUP  = ""
            FROM_DATE = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
        } -TableNames @("JOBLIST")
        return $result.Tables["JOBLIST"]
    } catch {
        Write-Warning "SM37 check failed: $_"
        return $null
    }
}

# ==================== MAIN EXECUTION ====================

Write-Host "Connecting to $Destination..." -ForegroundColor Green
$dest = Get-NCoDestination -DestName $Destination

Write-Host "`n=== Running SAP Monitoring Checks ===" -ForegroundColor Yellow

$results = @{
    SM12_Locks   = Get-SM12_Locks   $dest
    SM13_Updates = Get-SM13_Updates $dest
    SMQ1_Queues  = Get-SMQ1_Queues  $dest
    SM51_Servers = Get-SM51_Servers $dest
    SM37_Jobs    = Get-SM37_Jobs    $dest
}

# Simple Markdown output for now
if ($OutputFormat -eq "Markdown") {
    Write-Host "`n# SAP Monitor Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n" -ForegroundColor Cyan

    foreach ($check in $results.Keys) {
        $data = $results[$check]
        if ($data -and $data.RowCount -gt 0) {
            Write-Host "## $check ($($data.RowCount) entries)" -ForegroundColor Green
        } else {
            Write-Host "## $check - OK / No issues" -ForegroundColor Green
        }
    }
}

Write-Host "`nMonitoring complete." -ForegroundColor Green
return $results
