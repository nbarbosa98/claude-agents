# Gate 1: deterministic linter

```
python3 tools/lint/lint.py packages/<id> [--out gate1.json] [--no-pssa]
```

`lint.py` asks `Get-ScriptFacts.ps1` to parse each script with the PowerShell AST (the script
is never executed), then applies the rules below using `contract/stdout.json`, the canonical
`references/helpers.ps1` and the package's decision record. PSScriptAnalyzer runs through
`Invoke-PSSA.ps1` with `PSScriptAnalyzerSettings.psd1`, and its findings are merged in.

Result status: `PASS`; `FAIL` (any error); `PASS_PENDING_PSSA` (no errors, but
PSScriptAnalyzer is not installed, so the result is not deliverable). Exit codes 0 / 1 / 2.
Requirements: PowerShell 7 (`pwsh`), Python 3, PyYAML (`tools/requirements.txt`),
PSScriptAnalyzer for a full pass.

Rule changes need explicit owner approval (CLAUDE.md). Every rule has a mutation test in
`tools/tests/test_lint.py`.

| Rule id | Hard rule | Checks |
|---|---|---|
| L-ASCII | HR-01 | every byte of scripts and README is ASCII; no BOM |
| L-PLACEHOLDER | ADR-022 | no `__NAME__` or `<AppDisplayName>` left |
| L-PARSE / L-PS7 | HR-11 | parses; no PowerShell 7-only syntax |
| L-HEADER | skeleton | header Package/Type/Role match the package |
| L-ORDER | skeleton | constants, then helpers, then the main try; `$PACKAGE_ID`, `$SUBJECT` |
| L-HELPER-VERBATIM | skeleton | helper copies identical to `references/helpers.ps1` |
| L-HELPER-UNKNOWN (warning) | skeleton | non-canonical functions go to the reviewer |
| L-STATUS-TOKEN / L-STATUS-NONLITERAL | HR-02 | every `Exit-WithCode` token is a literal the contract allows for this type and role, with the contract's exit code |
| L-STDOUT | HR-02 | no stdout writes except `Exit-WithCode` and the outer catch's `ERROR` line |
| L-EXIT / L-CATCH-RETHROW | HR-03, HR-21 | raw `exit` only in `Exit-WithCode` and the outer catch (0 detect, 1 remediate); catch rethrows `ExitCalled:*` first |
| L-LOG | HR-10 | `Initialize-Log -PackageId $PACKAGE_ID -Role '<role>'` first; no log paths or globs outside helpers |
| L-WAIT / L-PROCESS / L-NONEWWINDOW | HR-05, HR-14 | no unbounded waits; processes only via `Invoke-ProcessWithTimeout` |
| L-WEB-TIMEOUT / L-IEX | HR-05, HR-07 | downloads only via `Invoke-FileDownload`; no `Invoke-Expression` |
| L-ENV | HR-06, HR-07 | no user-profile or TEMP environment variables |
| L-STAGING / L-TRUST | HR-07, HR-08 | installers staged in `$stagingDir`, trust-checked before any run, `.Trusted` checked, `finally` cleans up |
| L-TIMEOUT-CONST / L-BUDGET / L-TIMEOUT-LOOP (warning) | HR-04 | timeouts are `$TIMEOUT_*` integer constants; sum over call sites + 15 s per process helper <= 540 s |
| L-WINGET-RAW / L-WINGET-SOURCE / L-WINGET-PARITY / L-BROWSER / L-WINGET-AFTER-MSI | HR-15 | winget only via helpers; no source update; `$INCLUDE_UNKNOWN` parity; Browser has no winget upgrade; no winget after msiexec |
| L-AUDIT-READONLY / L-AUDIT-NOREMEDIATE | HR-16 | audit scripts change nothing and have no remediation script |
| L-REBOOT / L-HKCU | HR-20, HR-17 | no reboots, no process kills, no forced-restart flags, no HKCU |
| L-README | SKILL.md | README sections present and in order |
| L-DECISION | decision-record.md | valid decision record; stops on low confidence or open questions |
| PSSA-* | HR-11 | PSScriptAnalyzer, 5.1 syntax and command compatibility |

Known limits (reviewer covers them): messages are not matched against the contract's message
templates; splatted parameters in non-canonical code are not resolved; the budget counts a
call inside a loop once (flagged as L-TIMEOUT-LOOP).
