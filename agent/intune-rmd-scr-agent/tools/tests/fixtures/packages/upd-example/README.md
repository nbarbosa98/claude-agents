# upd-example (test fixture)

## Summary

Test fixture for Gates 1 and 2. Keeps the fictional "Example App" current through winget.
Not a deliverable package.

## Type and pattern

app-update, Pattern A (winget).

## Evidence

See decision-record.json (fixture values only).

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

Worst case (Gate 1): detect 75 s, remediate 390 s

detect: 60 s catalog + 15 s overhead. remediate: 60 s catalog + 300 s upgrade + 30 s overhead.

## Known failure modes

FM-01, FM-02, FM-03, FM-04, FM-05, FM-13.

## Rollback

Not applicable (fixture).

## UNVERIFIED items

winget under SYSTEM (ADR-016), `winget show --versions` output shape (ADR-019).
