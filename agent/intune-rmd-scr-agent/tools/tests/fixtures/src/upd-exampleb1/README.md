# upd-exampleb1 (test fixture)

## Summary

Test fixture for Gates 1 and 2. Updates the fictional "Example Tool" from a vendor MSI with
secure staging and an installer trust check. Not a deliverable package.

## Type and pattern

app-update, Pattern B1 (vendor direct).

## Evidence

See decision-record.json (fixture values only; the download host is a reserved .invalid name).

## Status tokens

detect: NOT_INSTALLED, SKIPPED_USER_SCOPE, NOT_DETERMINED, UP_TO_DATE, OUTDATED, ERROR.
remediate: NOT_INSTALLED, SKIPPED_USER_SCOPE, UP_TO_DATE, REMEDIATED, PENDING_REBOOT, FAILED, ERROR.

## Intune settings

| Setting | Value |
|---|---|
| Run as | SYSTEM |
| 64-bit PowerShell | Yes |
| Enforce signature check | No |

## Time budget

Worst case (Gate 1): detect 0 s, remediate 435 s

remediate: 120 s download + 300 s install + 15 s overhead.

## Known failure modes

FM-05, FM-07, FM-08, FM-09.

## Rollback

Not applicable (fixture).

## UNVERIFIED items

Signature-only trust (no published SHA256).
