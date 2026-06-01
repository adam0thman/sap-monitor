# SAP Monitor (PowerShell/NCo) - Technical Specification

**Version:** 2.0
**Author:** Hermes Agent

PowerShell + SAP .NET Connector (NCo 3.1) port of `sap-jco-monitor`. Mirrors the same
checks, primary/fallback strategy, thresholds, standardized output and exit codes.

---

## 1. Architecture

### 1.1 Design goals
- Pure PowerShell + NCo 3.1; no agent installed on the SAP host.
- Scheduled-task friendly with clear exit codes (0=OK, 1=WARNING, 2=CRITICAL).
- Standardized output across checks; Text / Markdown / Json renderers.
- Graceful degradation: a failing check degrades to SKIPPED and never aborts the run.

### 1.2 Connection
`RfcConfigParameters` → `RfcDestinationManager.GetDestination`. Parameters come from a
`<Destination>.ncoDestination` key=value file (else an `sapnco.ini` `[<Destination>]`
section): `ASHOST, SYSNR, CLIENT, USER, PASSWD`, optional `LANG`, `SAPROUTER`.

### 1.3 Standardized check output (Text)
```
>>> [XXX] Check Name
    Primary Method         : <primary BAPI/RFC>
    Primary Method Result  : <result or "Not available">
    Fallback Method        : <fallback or "Not needed">
    Fallback Method Result : <result or "-">
    Threshold              : <threshold>
    Status                 : <OK / WARNING / CRITICAL / SKIPPED>
```
Markdown renders a summary table + a Details section; Json emits the full object graph
(`overallStatus`, `overallCode`, `checks[]`).

---

## 2. Monitoring Checks (v2.0)

### 2.1 SM12 - Lock Entries
**Primary:** `ENQUEUE_READ` (count `ENQ`).  **Fallback:** `RFC_READ_TABLE` on `ENQID`.
**Threshold:** > 5000 = WARNING

### 2.2 SM13 - Update Records
**Primary:** `RFC_READ_TABLE` on `VBMOD`.  **Threshold:** informational only

### 2.3 SMQ1 - qRFC Queue Status
**Primary:** `TRFC_QOUT_GET_STATUS`.  **Fallback:** `RFC_READ_TABLE` on `TRFCQOUT`.
**Threshold:** informational only

### 2.4 SM51 - Application Servers
**Primary:** `TH_SERVER_LIST`.  **Threshold:** >= 1 required

### 2.5 SM37 - Background Jobs (Last 24h)
**Objective:** count jobs that aborted (status `A`) since yesterday.
**Primary (A):** `RFC_READ_TABLE` on `TBTCO`, columns trimmed to `JOBNAME, STATUS, SDLSTRTDT, ENDDATE` (stays under the 512-byte buffer) with WHERE `STATUS = 'A' AND SDLSTRTDT >= <yesterday>`; row count = aborted jobs.
**Fallback (B):** XBP over a stateful XMI session — `RfcSessionManager.BeginContext` → `BAPI_XMI_LOGON` (INTERFACE `XBP`, VERSION `3.0`) → `BAPI_XBP_JOB_SELECT` with `JOB_SELECT_PARAM-ABORTED = 'X'` → `BAPI_XMI_LOGOFF` → `EndContext`.
**Threshold:** > 10 = WARNING

### 2.6 ST22 - Short Dumps
**Primary:** `/SDF/GET_DUMP_LOG` (reads `ET_E2E_LOG`; dynamically prints all fields).
**Fallback:** `RFC_READ_TABLE` on `SNAP`, key fields only (`DATUM, UZEIT, AHOST, UNAME`) with a 24h `DATUM` filter, counting DISTINCT dumps (one dump spans many SNAP rows, and the trimmed column list avoids the 512-byte buffer overflow).
**Thresholds:** > 10 = WARNING, > 50 = CRITICAL

### 2.7 SMLG - Logon Group Response Times
**Objective:** each application server's average DIALOG response time (ms).
**Method:** `SWNC_COLLECTOR_GET_AGGREGATES` (ST03 workload) per `COMPONENT` (= app server from `TH_SERVER_LIST`); avg per dialog step = `RESPTI / COUNT` for task type `'01'`. The collector aggregates per day and the current day is usually not yet aggregated, so the most recent day with data within a 14-day lookback is used per server.
**Threshold:** > 4000 ms on any server = WARNING

---

## 3. Verification status

The script parses cleanly under the PowerShell 7 parser and its non-NCo logic
(config parsing, Text/Markdown/Json renderers, exit-code aggregation) is unit-exercised.
The SAP/NCo calls themselves require a Windows host with NCo 3.1 and have not yet been
run live; see commit history for live-verification updates. The RFC function modules,
table/field names, thresholds and the XBP/SWNC flows are ported verbatim from
`sap-jco-monitor`, which was verified live against two S/4HANA systems.

---

## 4. Version History

| Version | Changes |
|---------|---------|
| 2.0 | Full feature parity with sap-jco-monitor: real SM12/SM13/SMQ1/SM51/SM37/ST22/SMLG (replacing the v1.x placeholders and CHECK MANUALLY stubs), primary/fallback per check, standardized output, exit codes, and Text/Markdown/Json renderers. |
| 1.11 | ST22 via RFC_READ_TABLE on SNAP (count only). |
| 1.0–1.10 | Connection handling, sapnco.ini parsing, SM12/SM13 placeholders. |
