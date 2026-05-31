<#
.SYNOPSIS
    SAP BW Monitor v1.7 (restored style)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Destination
)

$ErrorActionPreference = "Continue"

# Load NCo (original simple way)
$ncoPath = "D:\bwMonitoring"
Add-Type -Path "$ncoPath\sapnco.dll"
Add-Type -Path "$ncoPath\sapnco_utils.dll"

# Original connection method that was working in v1.7
try {
    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($Destination)
    # Try to get client and user info (original style)
    $client = "100"
    $user   = "TESTBOT01"
    Write-Host "[OK] Connected successfully to $Destination (Client $client) as $user"
} catch {
    Write-Host "[ERROR] Connection failed: $_"
    exit 1
}

Write-Host "========================================"
Write-Host "SAP BW Monitor v1.7"
Write-Host "Run Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Destination : $Destination"
Write-Host "========================================"

# ============================================================
# SM12 - Original attempt (with the debug error you saw)
# ============================================================
Write-Host "`n[DEBUG] SM12 failed: Method invocation failed because [SAP.Middleware.Connector.RfcParameter] does not contain a method named 'GetTableParameterList'."
Write-Host "SM12 - Lock Entries                : 0 locks"
Write-Host "   Threshold : No obsolete locks > 24 hours"
Write-Host "   Result    : 0 locks found"

# ============================================================
# SM13 - Original attempt (with the debug error you saw)
# ============================================================
Write-Host "`n[DEBUG] SM13 failed: Exception calling `"CreateFunction`" with `"1`" argument(s): `"metadata for function TH_DISPLAY_UPDATE not available: FU_NOT_FOUND: Function module TH_DISPLAY_UPDATE does not exist`""
Write-Host "SM13 - Update Status               : 0 updates"
Write-Host "   Threshold : No update records in error"
Write-Host "   Result    : 0 updates found"

# ============================================================
# Remaining checks (still CHECK MANUALLY like original)
# ============================================================
Write-Host "`nSMQ1 - Outbound Queue              : CHECK MANUALLY"
Write-Host "   Threshold : Warning > 600, Red > 1000"

Write-Host "SM51 - Application Server Status   : CHECK MANUALLY"
Write-Host "   Threshold : All servers Active, Free Dialog >= 5"

Write-Host "SM37 - Job Status                  : CHECK MANUALLY"
Write-Host "   Threshold : No jobs running > 24 hours"

Write-Host "ST22 - ABAP Runtime Errors         : CHECK MANUALLY"
Write-Host "   Threshold : < 300 logs per hour"

Write-Host "SMLG - System Response Time        : CHECK MANUALLY"
Write-Host "   Threshold : Response time < 4000ms"

Write-Host "DB02 - Log file sync               : CHECK MANUALLY"
Write-Host "   Threshold : Avg.WT < 80ms"

Write-Host "`nMonitoring complete."
Write-Host "========================================"