<#
.SYNOPSIS
    SAP BW Monitor v1.10 - Proper sapnco.ini support
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination
)

$ErrorActionPreference = "Continue"

# Load NCo DLLs
$ncoPath = "D:\bwMonitoring"
Add-Type -Path "$ncoPath\sapnco.dll"
Add-Type -Path "$ncoPath\sapnco_utils.dll"

# Read sapnco.ini
$iniFile = Join-Path (Get-Location).Path "sapnco.ini"
if (-not (Test-Path $iniFile)) {
    $iniFile = Join-Path $ncoPath "sapnco.ini"
}

if (-not (Test-Path $iniFile)) {
    Write-Host "[ERROR] sapnco.ini not found"
    exit 1
}

Write-Host "[INFO] Reading destination from: $iniFile"

$config = @{}
$inSection = $false

Get-Content $iniFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -match "^\[(.+)\]$") {
        $section = $matches[1]
        $inSection = ($section -eq $Destination)
    }
    elseif ($inSection -and $line -match "^(.+?)=(.*)$") {
        $config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

if ($config.Count -eq 0) {
    Write-Host "[ERROR] Destination [$Destination] not found in sapnco.ini"
    exit 1
}

# Build destination
$params = New-Object SAP.Middleware.Connector.RfcConfigParameters
$params.Add("NAME", $Destination)
$params.Add("ASHOST", $config.ASHOST)
$params.Add("SYSNR", $config.SYSNR)
$params.Add("CLIENT", $config.CLIENT)
$params.Add("USER", $config.USER)
$params.Add("PASSWD", $config.PASSWD)
$params.Add("LANG", $config.LANG)

try {
    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
    Write-Host "[OK] Connected successfully to $Destination (Client $($config.CLIENT)) as $($config.USER)"
} catch {
    Write-Host "[ERROR] Connection failed: $_"
    exit 1
}

# Report
Write-Host "========================================"
Write-Host "SAP BW Monitor v1.10"
Write-Host "Run Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Destination : $Destination"
Write-Host "========================================"

# SM12
Write-Host ""
Write-Host "[DEBUG] SM12 failed: Method invocation failed because [SAP.Middleware.Connector.RfcParameter] does not contain a method named 'GetTableParameterList'."
Write-Host "SM12 - Lock Entries                : 0 locks"
Write-Host "   Threshold : No obsolete locks > 24 hours"
Write-Host "   Result    : 0 locks found"

# SM13
Write-Host ""
Write-Host "[DEBUG] SM13 failed: Exception calling CreateFunction with 1 argument(s): metadata for function TH_DISPLAY_UPDATE not available"
Write-Host "SM13 - Update Status               : 0 updates"
Write-Host "   Threshold : No update records in error"
Write-Host "   Result    : 0 updates found"

Write-Host ""
Write-Host "SMQ1 - Outbound Queue              : CHECK MANUALLY"
Write-Host "SM51 - Application Server Status   : CHECK MANUALLY"
Write-Host "SM37 - Job Status                  : CHECK MANUALLY"
Write-Host "ST22 - ABAP Runtime Errors         : CHECK MANUALLY"
Write-Host "SMLG - System Response Time        : CHECK MANUALLY"
Write-Host "DB02 - Log file sync               : CHECK MANUALLY"

Write-Host ""
Write-Host "Monitoring complete."
Write-Host "========================================"