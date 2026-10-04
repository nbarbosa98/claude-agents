# Type: audit

Reports a fact about devices without changing anything. Detection script only; no
remediation script is deployed. Package id prefix: `aud-`.

## Behaviour

- Exit 1 when a finding exists (`AUDIT_FINDING`), so Intune counts the device as "with
  issues". With no remediation script, exit 1 changes nothing on the device.
- Exit 0 when clean (`AUDIT_CLEAN`), or `NOT_DETERMINED` when the fact cannot be read.

## Output

`<TOKEN> | <Subject> audit <clean|finding>: key=value;key=value` within 512 characters.
Counts and identifiers only (HR-18): for example `localAdmins=3;unexpected=1`, never the
account names.

## Constants

```powershell
$CHECK_NAME = '__CHECK_NAME__'
$TIMEOUT_COLLECT = 60
```

## Read-only (HR-16)

The linter bans every state-changing command in audit scripts. The only write is the log
file via `Initialize-Log`.
