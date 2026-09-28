# Gate 2: Pester harness

```
pwsh -NoProfile -File tools/pester/Invoke-Gate2.ps1 -PackagePath packages/<id> [-OutFile gate2.json]
```

- `Invoke-Gate2.ps1` picks `matrices/<type>-<pattern>.ps1` (else `matrices/<type>.ps1`),
  appends `<package>/tests/*.scenarios.ps1` if present, checks coverage, runs
  `Package.Tests.ps1`, and prints JSON.
- `Package.Tests.ps1` parses the script, dot-sources its constants and helpers, mocks the
  side-effecting helpers, runs the main `try` block per scenario and asserts the single
  `Exit-WithCode` token and code (or the outer catch's `ERROR` line). A raw `exit` in the
  outer catch is rewritten to a throw so the test process survives.
- `Mocks.ps1` holds shared mock builders (`New-AppState`, `New-ProcResult`,
  `New-TrustResult`, `New-MachineInstall`, `New-UserInstall`, `Step-G2Counter`).
  Default mocks: `Exit-WithCode` throws `ExitCalled:<code>`; logging and `Write-Host` are
  captured.

Coverage rule: every token a script can emit (each literal `Exit-WithCode` token, plus
`ERROR`) needs at least one scenario; missing ones are listed in `uncovered` and fail the
gate. Fewer scenarios than call sites for a token are listed in `undercovered` (reviewer).

Status: `PASS`; `FAIL`; `PASS_PENDING_WINDOWS` when scenarios marked `WindowsOnly` were
skipped because they need Windows cmdlet behaviour (they run in the Gate 4 VM, Phase 3).
Off Windows the harness sets `SystemRoot`, `ProgramData`, `ProgramFiles`, `SystemDrive`
and maps a `C:` drive to a temp folder so path building works; nothing is written there.

Helper unit tests: `helpers/Helpers.Tests.ps1` (any OS) and
`helpers/Helpers.Windows.Tests.ps1` (Windows only: ACLs, registry, process kill).

Matrices are tests: never weaken one to make a package pass (CLAUDE.md).

| Matrix | Scenarios |
|---|---|
| `app-update-A.ps1` | absent, user-scope only, unreadable, winget missing (fail open), winget hang, up to date, newer than catalog, outdated, exception; remediation: absent, user-scope, idempotent, winget missing, catalog unavailable, verified success, exit 0 without new version, reboot to finish, timeout, exception |
| `app-update-B1.ps1` | detection paths; remediation: idempotent without download, trust failure installs nothing, verified success, 3010, installer failure, exit 0 without new version, download error still cleans staging |
| `config-change.ps1` | compliant, drifted, exception; idempotent, corrected, reboot, write does not stick, write throws |
| `audit.ps1` | absent, clean, finding, read error (3 are WindowsOnly) |

Not yet written (added with the first package of that kind): Browser, B2, B3,
vuln-remediation, general.
