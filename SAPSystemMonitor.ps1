<#
.SYNOPSIS
    SAP BW / S/4HANA System Monitor using SAP .NET Connector (NCo) 3.1
.VERSION
    1.9
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination
)

$ErrorActionPreference = "Stop"

# ============================================================
# Load SAP NCo DLLs (flexible - works from your D:\bwMonitoring folder)
# ============================================================
$ncoBase = $PSScriptRoot
if (-not $ncoBase) { $ncoBase = (Get-Location).Path }

$sapnco = Join-Path $ncoBase "sapnco.dll"
if (-not (Test-Path $sapnco)) {
    $sapnco = "D:\bwMonitoring\sapnco.dll"
}

Add-Type -Path $sapnco -ErrorAction Stop
Add-Type -Path (Join-Path (Split-Path $sapnco) "sapnco_utils.dll") -ErrorAction Stop

# ============================================================
# Destination loading - RESTORED to the method that worked in v1.6/v1.7
# ============================================================
try {
    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($Destination)
    Write-Host "[OK] Connected successfully to $Destination" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Destination '$Destination' not found or connection failed: $_" -ForegroundColor Red
    Write-Host "Make sure TBL is properly registered in your NCo configuration (App.config or destination file)." -ForegroundColor Yellow
    exit 1
}

# ============================================================
# Safe RFC Invocation Helper (NCo 3.1 compatible)
# ============================================================
function Invoke-RfcFunction {
    param(
        $Destination,
        [string]$FunctionName,
        [hashtable]$Parameters = @{},
        [string[]]$TableNames = @()
    )

    try {
        $func = $Destination.Repository.CreateFunction($FunctionName)
    } catch {
        Write-Host "[DEBUG] $FunctionName not available on this system" -ForegroundColor DarkYellow
        return $null
    }

    foreach ($key in $Parameters.Keys) {
        try { $func.SetValue($key, $Parameters[$key]) } catch {}
    }

    try {
        $func.Invoke($Destination)
    } catch {
        Write-Host "[DEBUG] Invoke failed for $FunctionName : $_" -ForegroundColor DarkYellow
        return $null
    }

    $tables = @{}
    foreach ($t in $TableNames) {
        try {
            $tbl = $func.GetTable($t)
            if ($tbl) { $tables[$t] = $tbl }
        } catch {}
    }

    return @{ Function = $func; Tables = $tables }
}

# ============================================================
# Monitoring Report
# ============================================================
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "========================================"
Write-Host "SAP BW Monitor v1.9"
Write-Host "Run Time : $now"
Write-Host "Destination : $Destination"
Write-Host "========================================"

# SM12
Write-Host "`nSM12 - Lock Entries" -NoNewline
$result = Invoke-RfcFunction -Destination $dest -FunctionName "ENQUEUE_READ" `
    -Parameters @{ GCLIENT = "100" } -TableNames @("ENQ")

if ($result -and $result.Tables.ContainsKey("ENQ")) {
    Write-Host "                : $($result.Tables['ENQ'].Count) locks"
} else {
    Write-Host "                : CHECK MANUALLY"
}

# SM13
Write-Host "SM13 - Update Status               : CHECK MANUALLY (TH_DISPLAY_UPDATE not available)"

# SMQ1
Write-Host "SMQ1 - Outbound Queue              : CHECK MANUALLY"

# SM51
Write-Host "SM51 - Application Server Status   : CHECK MANUALLY"

# SM37
Write-Host "SM37 - Job Status                  : CHECK MANUALLY"

# Others
Write-Host "ST22 - ABAP Runtime Errors         : CHECK MANUALLY"
Write-Host "SMLG - System Response Time        : CHECK MANUALLY"
Write-Host "DB02 - Log file sync               : CHECK MANUALLY"

Write-Host "`nMonitoring complete."
Write-Host "========================================"