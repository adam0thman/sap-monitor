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
    ".\nco\sapnco.dll",                    # preferred subfolder
    ".\sapnco.dll",                        # same folder as script
    "$PSScriptRoot\nco\sapnco.dll",
    "$PSScriptRoot\sapnco.dll",
    "C:\Program Files\SAP\NCo\sapnco.dll"  # common install location
) | Where-Object { Test-Path $_ }

if ($ncoPaths) {
    $dllPath = $ncoPaths | Select-Object -First 1
    Write-Host "Loading NCo from: $dllPath" -ForegroundColor Cyan
    Add-Type -Path $dllPath
    Add-Type -Path ($dllPath -replace 'sapnco\.dll$', 'sapnco_utils.dll')
} else {
    Write-Error "SAP NCo DLLs not found. Place sapnco.dll + sapnco_utils.dll in the script folder or in a 'nco' subfolder."
    exit 1
}

function Get-NCoDestination {
    param([string]$DestName)
    $cfg = [SAP.Middleware.Connector.RfcConfigParameters]::new()
    # Load from .ncoDestination file logic here (simplified)
    # In real implementation: parse INI-style file and register
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

    # Set importing parameters
    foreach ($key in $Parameters.Keys) {
        if ($func.GetImportingParameterList().Contains($key)) {
            $func.SetValue($key, $Parameters[$key])
        }
    }

    $func.Invoke($Destination)

    # Handle table output parameters (the fixed pattern)
    $tables = @{}
    foreach ($tableName in $TableNames) {
        if ($func.GetTableParameterList().Contains($tableName)) {
            $tables[$tableName] = $func.GetTableParameterList().GetTable($tableName)
        }
    }

    return @{
        Function   = $func
        Tables     = $tables
    }
}

# Main monitoring logic placeholder
Write-Host "Connecting to $Destination..."
$dest = Get-NCoDestination -DestName $Destination

# TODO: Implement the 8 monitoring checks using NCo RFC calls
# (See references/ for detailed RFC patterns)

Write-Host "Monitoring complete. Output format: $OutputFormat"
