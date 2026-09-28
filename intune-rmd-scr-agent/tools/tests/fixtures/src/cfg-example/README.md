# cfg-example (test fixture)

## Summary

Test fixture for Gates 1 and 2. Enforces a fictional registry value and service start type.
Not a deliverable package.

## Type and pattern

config-change (desired state).

## Evidence

See decision-record.json (fixture values only).

## Status tokens

detect: COMPLIANT, DRIFTED, ERROR. remediate: COMPLIANT, REMEDIATED, PENDING_REBOOT, FAILED, ERROR.

## Intune settings

| Setting | Value |
|---|---|
| Run as | SYSTEM |
| 64-bit PowerShell | Yes |

## Time budget

No external processes; no timeouts declared.

## Known failure modes

FM-10, FM-11, FM-12.

## Rollback

Restore the prior values logged as ROLLBACK lines in the remediation log.

## UNVERIFIED items

None beyond the platform items in platform.md.
