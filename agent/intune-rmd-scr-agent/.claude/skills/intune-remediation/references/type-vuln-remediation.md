# Type: vuln-remediation

Closes a named exposure (CVE IDs or a Defender vulnerability recommendation) on Windows
devices. Package id prefix: `vuln-`.

## Refuse and route instead

- The fix is an OS cumulative update: refuse; use Windows Update for Business / Autopatch.
- The fix is Microsoft 365 Apps (Click-to-Run): refuse; use M365 Apps update channels.

## Evidence required (decision record)

- CVE IDs (or recommendation ID) and the vendor advisory URL for each.
- Affected product and affected version range, from the advisory.
- Fix kind: `version` (fixed-in version) or `mitigation` (documented registry, feature or
  service change), with the advisory text that states it.
- Whether the mitigation needs a reboot (from the advisory).
No advisory, no package: the classifier returns an open question instead.

## Constants

```powershell
$CVE_IDS          = 'CVE-YYYY-NNNNN'   # comma-separated, shown in status messages
$FIX_KIND         = 'version'          # or 'mitigation'
$AFFECTED_MIN     = '0.0.0.0'          # inclusive, from advisory (version kind)
$FIXED_VERSION    = '__FIXED_VERSION__'# first fixed version (version kind)
$DESIRED          = @()                # desired-state entries (mitigation kind)
$REBOOT_REQUIRED  = $false             # from advisory (mitigation kind)
```

Version kind also uses the app-update constants for discovery and install.

## Detection

- Version kind: run the app-update installed-version routine (which already handles
  `SKIPPED_USER_SCOPE`), with its `NOT_INSTALLED` exit replaced by `NOT_APPLICABLE`
  (`NOT_INSTALLED` is not a vuln-remediation token). Exposed when
  `$AFFECTED_MIN <= installed < $FIXED_VERSION`: `EXPOSED`, exit 1. Otherwise `NOT_EXPOSED`.
- Mitigation kind: if the targeted component is absent: `NOT_APPLICABLE`. If every
  `$DESIRED` entry passes `Test-DesiredStateEntry`: `NOT_EXPOSED` (or `PENDING_REBOOT` when
  a reboot-required mitigation was applied and the device has not rebooted since, if the
  package can tell; otherwise `NOT_EXPOSED`). Else `EXPOSED`, exit 1.
- The message always names the CVE IDs, so the Intune output column shows which exposure
  a device has.

## Remediation

- Version kind: the app-update remediation block for the app's pattern (one code path),
  with target = `$FIXED_VERSION` or the catalog version, whichever is higher. Success
  token is `MITIGATED` (or `STAGED` / `PENDING_REBOOT`), failure is `FAILED`.
- Mitigation kind: `Set-DesiredStateEntry` for each failing entry (logs the prior value for
  rollback), then re-test. All pass: `MITIGATED`, or `PENDING_REBOOT` if
  `$REBOOT_REQUIRED`. Any fail: `FAILED`, exit 1.
- Uninstalling software to close an exposure needs the owner's explicit approval recorded
  in the decision record; the reviewer flags it otherwise.
