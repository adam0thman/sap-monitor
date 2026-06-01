# NCo RFC Invocation Patterns

How this project calls RFC functions with the SAP .NET Connector 3.1 from PowerShell.
These are the idioms `SAPSystemMonitor.ps1` relies on (NCo's API differs from Java/JCo,
which is what earlier versions of this script kept tripping over).

## Load + connect
```powershell
Add-Type -Path "D:\bwMonitoring\sapnco.dll"
Add-Type -Path "D:\bwMonitoring\sapnco_utils.dll"

$params = New-Object SAP.Middleware.Connector.RfcConfigParameters
$params.Add("NAME", "S4D"); $params.Add("ASHOST", $h); $params.Add("SYSNR", "00")
$params.Add("CLIENT", "100"); $params.Add("USER", $u); $params.Add("PASSWD", $p)
$dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
$attr = $dest.Attributes          # .SystemID  .Client  .User
```

## Call a function
```powershell
$fn = $dest.Repository.CreateFunction("RFC_READ_TABLE")   # NOT GetFunction
$fn.SetValue("QUERY_TABLE", "TBTCO")                       # scalar import
$fn.Invoke($dest)                                          # NOT execute
$data = $fn.GetTable("DATA")                               # IRfcTable
```

## Tables (IRfcTable)
- `$t.RowCount` — number of rows (NOT `.Count`).
- Append + fill a row: `$t.Append(); $t.SetValue("FIELDNAME", $v)` — `Append()` positions
  the cursor on the new row; there is **no** `AppendRow()` returning a row object.
- Iterate: `for ($i=0; $i -lt $t.RowCount; $i++) { $t.CurrentIndex = $i; $t.GetString("F") }`
- Typed reads: `GetString`, `GetInt`, `GetLong`, `GetDouble`.
- Dynamic fields: `$t.Metadata.LineType.FieldCount` and `$t.Metadata.LineType[$i].Name`.

## Structures (IRfcStructure)
```powershell
$p = $fn.GetStructure("JOB_SELECT_PARAM")
$p.SetValue("ABORTED", "X")
```

## Stateful sessions (XBP / XMI)
XBP BAPIs need one connection across logon -> select -> logoff:
```powershell
[SAP.Middleware.Connector.RfcSessionManager]::BeginContext($dest)
try { <# BAPI_XMI_LOGON ... BAPI_XBP_JOB_SELECT ... BAPI_XMI_LOGOFF #> }
finally { [SAP.Middleware.Connector.RfcSessionManager]::EndContext($dest) }
```

## Errors
ABAP exceptions surface as `RfcAbapException`; inspect `$_.Exception.Message` for keys
like `NO_DATA_FOUND` / `NO_GROUPS_FOUND` and treat them as functional results, not crashes.

## RFC_READ_TABLE gotcha
The `DATA` rows use a 512-byte buffer. Selecting all columns of a wide table (TBTCO, SNAP)
throws `DATA_BUFFER_EXCEEDED` — always restrict `FIELDS` to the few columns you need.
