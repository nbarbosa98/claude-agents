# aud-example (test fixture)

## Summary

Test fixture for Gates 1 and 2. Counts legacy plugin files of a fictional app. Changes nothing.

## Type and pattern

audit (detection only, no remediation script).

## Evidence

See decision-record.json (fixture values only).

## Status tokens

detect: AUDIT_CLEAN, AUDIT_FINDING, ERROR.

## Intune settings

| Setting | Value |
|---|---|
| Remediation script | None |
| Run as | SYSTEM |
| 64-bit PowerShell | Yes |

## Time budget

Worst case (Gate 1): detect 0 s

No external processes; no timeouts declared.

## Known failure modes

FM-10, FM-11.

## Rollback

Not applicable (read-only).

## UNVERIFIED items

None beyond the platform items in platform.md.
