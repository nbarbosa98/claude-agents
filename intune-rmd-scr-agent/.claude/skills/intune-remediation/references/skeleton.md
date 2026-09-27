# Script skeleton

Every script is built from `templates/detect.skeleton.ps1` or
`templates/remediate.skeleton.ps1`. The section order is fixed and checked by Gate 1:

1. **Header comment**: package id, type, role, contract version, generator id, summary.
2. **Constants**: `$PACKAGE_ID`, `$SUBJECT`, then the type constants. Every timeout is a
   `$TIMEOUT_*` constant in seconds (HR-04).
3. **Helpers**: the helper functions this script calls, copied verbatim from
   `helpers.ps1`, in the order they appear there. Only helpers that are used.
4. **Main**: `try { Initialize-Log ...; <body> } catch { <rethrow ExitCalled>; ERROR line; exit }`,
   plus `finally { Remove-SecureStagingDir ... }` in remediation.

## Placeholders

Templates use `__NAME__` placeholders. A delivered script contains none (Gate 1 checks
the pattern `__[A-Z][A-Z0-9_]*__`).

| Placeholder | Filled with |
|---|---|
| `__PACKAGE_ID__` | package id, for example `upd-7zip` |
| `__SCRIPT_TYPE__` | `app-update`, `vuln-remediation`, `config-change`, `audit`, `general` |
| `__CONTRACT_VERSION__` | `contractVersion` from `contract/stdout.json` |
| `__GENERATOR_ID__` | generator subagent name and ISO date |
| `__ONE_LINE_SUMMARY__` | one line, ASCII |
| `__SUBJECT__` | app display name or check name used in messages |
| `__TYPE_CONSTANTS__` | constants from the type reference |
| `__HELPERS__` | copied helper functions |
| `__DETECT_BODY__` / `__REMEDIATE_BODY__` | body from the type reference |

## Rules the skeleton already satisfies

- HR-03: the outer catch rethrows `ExitCalled:*` as its first statement.
- HR-21: detection's outer catch exits 0 with `ERROR`; remediation's exits 1.
- HR-07: remediation removes the staging dir in `finally` (`exit` inside `try` still runs
  `finally`; observed in PowerShell 7 on Linux, to be confirmed on 5.1 in the lab).
- HR-10: `Initialize-Log` is the first statement.

## Body conventions

- Every path through the body ends in `Exit-WithCode`. Falling off the end of the body is
  a defect (the IME would see exit 0 with empty output, which it treats as "no issue").
- Log decisions with `Write-Log` before calling `Exit-WithCode`.
- Indent bodies by 4 spaces inside `try`.
