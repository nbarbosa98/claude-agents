# Type: config-change

Enforces a desired setting state (registry values, service start types) on Windows
devices. Package id prefix: `cfg-`.

## First: is a configuration profile the better tool?

Before generating, the generator checks (and cites) whether Settings Catalog or a CSP can
set this value. If yes, it returns to the orchestrator with the recommendation: a profile
is declarative, reports natively and has no script to maintain. It generates the script
only when the owner still wants it; the reason goes into the README `## Summary`.

## Constants

```powershell
$DESIRED = @(
    @{ Kind = 'Registry'; Path = 'HKLM:\SOFTWARE\...'; Name = '...'; Type = 'DWord'; Value = 1 },
    @{ Kind = 'Service';  Name = '...'; StartType = 'Disabled'; StopIfRunning = $false; AbsentIsCompliant = $true }
)
$REBOOT_REQUIRED = $false   # true only when the source for the setting says so
```

v1 supports `Registry` (types `String`, `ExpandString`, `DWord`, `QWord`) under `HKLM:` and
`Service` (`StartType` `Automatic`, `Manual`, `Disabled`). Anything else needs a reference
and contract change first.

## Detection

Evaluate every entry with `Test-DesiredStateEntry`. All pass: `COMPLIANT`, exit 0. Else
`DRIFTED` with the count and entry names (names only, never values that could be
sensitive), exit 1.

## Remediation

Re-evaluate (HR-19). For each failing entry, `Set-DesiredStateEntry` (logs the prior value
as `ROLLBACK ...` first). Re-evaluate all entries. All pass: `REMEDIATED` (or
`PENDING_REBOOT` if `$REBOOT_REQUIRED`). Any fail: `FAILED`, exit 1.

## Guardrails (HR-17)

Blocked unless the owner's approval is recorded: weakening Defender AV, Firewall, UAC,
BitLocker, Windows Update, SmartScreen, LSA protection, Credential Guard, audit logging;
any write under `HKCU` or another user's hive.

## Rollback

The README `## Rollback` section lists every entry and how to restore it; the per-device
prior values are in the remediation log (`ROLLBACK` lines).
