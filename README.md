# SAP Monitor (PowerShell + NCo)

SAP system monitoring and landscape discovery tool built with PowerShell and SAP .NET Connector (NCo) 3.1.

## Purpose
Automated monitoring of SAP systems (S/4HANA, BW, ECC) for:
- Lock entries (SM12)
- Update errors (SM13)
- Queue status (SMQ1/SMQ2)
- Server status (SM51)
- Background jobs (SM37)
- Short dumps (ST22)
- Logon groups (SMLG)
- Database space (DB02)

## Requirements
- Windows with PowerShell 5.1+ or PowerShell 7+
- SAP .NET Connector 3.1 (sapnco.dll + sapnco_utils.dll)
- Valid SAP user with RFC access

## Quick Start

```powershell
# 1. Configure destinations
notepad S4D.ncoDestination

# 2. Run monitoring
.\SAPSystemMonitor.ps1 -Destination S4D -OutputFormat Markdown
```

## Project Structure
```
sap-monitor/
├── SAPSystemMonitor.ps1
├── *.ncoDestination
├── README.md
├── docs/
└── references/
```

## Output
- Markdown reports (for executive / second-brain use)
- JSON (for automation / dashboards)
- HTML (optional)

## License
Internal tool – not for public distribution.
