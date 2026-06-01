# SAP Monitor (PowerShell + NCo)

SAP system monitoring tool built with PowerShell and the SAP .NET Connector (NCo) 3.1.
PowerShell/NCo counterpart of [sap-jco-monitor](https://github.com/adam0thman/sap-jco-monitor)
(Java/JCo) — same checks, primary/fallback strategy, thresholds and exit codes.

## Purpose
Automated RFC-based monitoring of SAP systems (S/4HANA, BW, ECC) for:

- Lock entries (SM12) — `ENQUEUE_READ`, > 5000 = WARNING
- Update records (SM13) — `RFC_READ_TABLE` on `VBMOD`, informational
- Queue status (SMQ1) — `TRFC_QOUT_GET_STATUS`, informational
- Application server status (SM51) — `TH_SERVER_LIST`, >= 1 required
- Background jobs (SM37) — aborted jobs in last 24h, > 10 = WARNING
- Short dumps (ST22) — `/SDF/GET_DUMP_LOG`, > 10 = WARNING, > 50 = CRITICAL
- Logon group response times (SMLG) — per-server dialog response time, > 4000 ms = WARNING

Exit codes (max across all checks): **0 = OK, 1 = WARNING, 2 = CRITICAL** (ideal for
scheduled tasks + alerting). See `docs/TECHNICAL_SPECIFICATION.md` for the full design.

## Requirements
- Windows with PowerShell 5.1+ or PowerShell 7+
- SAP .NET Connector 3.1 (`sapnco.dll` + `sapnco_utils.dll`), by default in `D:\bwMonitoring`
- A SAP user with RFC authorization for the monitored function modules

## Quick Start

```powershell
# 1. Configure a destination (real .ncoDestination files are git-ignored)
Copy-Item S4D.ncoDestination.template S4D.ncoDestination
notepad S4D.ncoDestination

# 2. Run monitoring (Text is default; Markdown / Json also supported)
.\SAPSystemMonitor.ps1 -Destination S4D
.\SAPSystemMonitor.ps1 -Destination S4D -OutputFormat Markdown
.\SAPSystemMonitor.ps1 -Destination S4D -OutputFormat Json

# Override the NCo DLL location if not D:\bwMonitoring
.\SAPSystemMonitor.ps1 -Destination S4D -NcoPath C:\nco
```

The destination name maps to `<Destination>.ncoDestination` in the current folder
(key=value: `ASHOST`, `SYSNR`, `CLIENT`, `USER`, `PASSWD`, optional `LANG`, `SAPROUTER`).
If that file is absent it falls back to a `[<Destination>]` section in `sapnco.ini`.

## Scheduled Task example

```powershell
# Run every 5 minutes, append JSON to a log for a dashboard to consume
powershell -File C:\sap-monitor\SAPSystemMonitor.ps1 -Destination S4D -OutputFormat Json >> C:\logs\sap-monitor.json
```

## Project Structure
```
sap-monitor/
├── SAPSystemMonitor.ps1
├── S4D.ncoDestination.template   # committed; copy to S4D.ncoDestination
├── *.ncoDestination              # your real creds (git-ignored)
├── README.md
├── docs/TECHNICAL_SPECIFICATION.md
└── references/nco-rfc-invocation.md
```

## Output
- **Text** (default) — standardized `Primary / Fallback / Threshold / Status` per check
- **Markdown** — summary table + details (executive / second-brain use)
- **Json** — for automation / dashboards

## License
Internal tool – not for public distribution.
