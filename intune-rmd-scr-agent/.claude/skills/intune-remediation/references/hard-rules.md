# Hard rules

Every generated script must satisfy every rule that applies to its type. A rule marked
**Gate 1** is checked mechanically by the linter; the reviewer (Gate 3) checks the rest
and re-checks the intent of all of them.

## HR-01 ASCII only

Every byte is in the range 0x00-0x7F. Banned characters, named because they cannot be
shown here: em dash, en dash, left and right curly single quotes, left and right curly
double quotes, the ellipsis character, arrow characters, non-breaking space, byte-order
mark. Use `-`, `'`, `"`, `...`, `->` instead.
Why: Intune requires UTF-8 (no BOM when signature check is on); ASCII is identical in
UTF-8 and Windows-1252, so encoding can never corrupt a script.

## HR-02 One status line from the contract

Each run writes exactly one status line, `<TOKEN> | <message>`, through `Exit-WithCode`.
The token must be allowed for the package's type and for this script (detect or
remediate) in `contract/stdout.json`, with the exit code the contract gives. The only other permitted
stdout write is the outer catch's `ERROR` line in the skeleton, which must not depend on
any helper. No other `Write-Host` or `Write-Output`. Diagnostics go to the log.

## HR-03 Exit discipline

- `Exit-WithCode` (copied verbatim from helpers.ps1) is the only way to finish a run.
- A raw `exit` appears only inside `Exit-WithCode` and in the outer `catch`.
- The first statement in the outer `catch` rethrows `ExitCalled:*` errors, so Pester
  tests (which mock `Exit-WithCode` to throw) see the intended exit.

## HR-04 Time budget

All timeouts are `$TIMEOUT_*` constants (seconds) in the constants block. No literal
timeout values elsewhere. The sum of all `$TIMEOUT_*` values must be <= 540. The
platform timeout is UNVERIFIED (see platform.md); 540 is the design ceiling.

## HR-05 Bounded waits

- No `WaitForExit()` without an argument; use `Invoke-ProcessWithTimeout`.
- `Start-Process -Wait` is banned (unbounded).
- `Invoke-WebRequest` / `Invoke-RestMethod` always carry `-TimeoutSec`.
- No `Wait-Process` without `-Timeout`, no `Start-Sleep` loops without a deadline.

## HR-06 No user-profile environment variables

`$env:LOCALAPPDATA`, `$env:APPDATA`, `$env:USERPROFILE`, `$env:HOMEPATH`, `$env:HOMEDRIVE`
and `$env:USERNAME` are banned. Under SYSTEM they point at the system profile, so
per-user installs are never found. User profiles come from the ProfileList registry key
(`Get-UserScopeInstalls`).

## HR-07 Secure staging

Anything that will be executed (installers, MSI, MSP, archives to extract) is written only
into a directory from `New-SecureStagingDir`, and removed with `Remove-SecureStagingDir`
in a `finally` block. Staging under `$env:TEMP` (which is `C:\Windows\Temp` under SYSTEM)
is banned. Exception: `Invoke-ProcessWithTimeout`'s stdout/stderr capture files, which are
never executed.

## HR-08 Installer trust

`Test-InstallerTrust` is called immediately before an installer runs, with the expected
signer CN and O from the decision record, and the SHA256 when the vendor publishes one.
Authenticode status must be `Valid`. On failure: no install, `FAILED` with the reason,
exit 1. There is no "warn and proceed" path.

## HR-09 Scope model (ADR-012, D2)

- Detection looks at machine scope: HKLM Uninstall in both registry views, and the
  `Program Files` locations named in the decision record.
- If the app is not installed machine-wide, look for user-scope installs with
  `Get-UserScopeInstalls`. If only user-scope installs exist: `SKIPPED_USER_SCOPE`, exit 0.
- Remediation installs machine scope only (`--scope machine`, or the vendor's machine-wide
  installer). It never installs, updates or removes per-user copies.

## HR-10 Logging (ADR-012, D3)

`Initialize-Log -PackageId <id> -Role <detect|remediate>` is the first statement in the
main block. Logs go to `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` as
`IntuneRem_<package-id>_<role>_<yyyyMMdd-HHmmss>.log`. Pruning is only by
`IntuneRem_<package-id>_*.log`. Any other glob in that folder is banned.

## HR-11 Windows PowerShell 5.1 syntax

Banned: ternary `? :`, `??`, `??=`, `?.`, `?[]`, pipeline chains `&&` / `||`,
`ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`, `Get-Content -AsByteStream`,
`clean {}` blocks, `$PSStyle`, classes that use PowerShell 7-only features. Use
`[Parameter(Mandatory = $true)]` (explicit `$true`).

## HR-12 Versions

- Always compare `ConvertTo-NormalizedVersion` results (4-part `[version]`); never compare
  version strings.
- Trust order for the installed version: numeric file version parts of the main
  executable (`Get-FileVersionSafe`), then registry `DisplayVersion`. The decision record
  names which one matches the catalog format for this app.
- App-type scripts get the installed version only through `Get-InstalledAppVersion`, in
  both detection and remediation, so the two can never disagree (FM-13).
- If the installed or target version cannot be parsed: `NOT_DETERMINED`, exit 0.

## HR-13 Never overstate

`REMEDIATED` / `MITIGATED` only after a post-check confirms the new state on disk or in
the registry. A staged update is `STAGED`; a change that needs a reboot is
`PENDING_REBOOT`. Never state that an app is patched when only a staged update exists.

## HR-14 Installer processes

Installers run through `Invoke-ProcessWithTimeout` (which uses `Start-Process -NoNewWindow
-PassThru` and a bounded `WaitForExit(ms)`). MSI: `msiexec.exe /i <path> /qn /norestart`
with a verbose log into the staging dir, copied to the package log on failure.

## HR-15 winget (Pattern A only)

- Running `winget.exe` as SYSTEM is unsupported by Microsoft (ADR-016). Locate it only
  with `Get-WingetPath`; call it only through `Invoke-Winget`, which adds the required
  flags (`--id`, `--exact`, `--source winget`, `--accept-source-agreements`,
  `--disable-interactivity`; for upgrade also `--scope machine`, `--silent`,
  `--accept-package-agreements`).
- Currency is decided by comparing versions (`Get-WingetCatalogVersion` against the
  installed version), never by the presence or absence of text in winget output.
- If detection passes `-IncludeUnknown` semantics (treats unknown installed version as
  outdated), remediation passes `-IncludeUnknown` too, and vice versa.
- Browser pattern remediation never calls `winget upgrade` and never runs
  `winget source update`.
- No winget call after an `msiexec` call in the same script.

## HR-16 Audit scripts change nothing

Audit detection scripts must not change device state. Banned: `Set-*`, `New-Item` and
`New-ItemProperty` (except the log file via `Initialize-Log`), `Remove-*` (except log
pruning in `Initialize-Log`), `Stop-*`, `Start-Service`, `Restart-*`, `reg.exe add/delete`,
`sc.exe config`, installers, `Invoke-WebRequest` downloads.

## HR-17 Config-change guardrails

The reviewer blocks, unless the owner's explicit approval is recorded in the decision
record, any change that turns off or weakens: Microsoft Defender Antivirus, Windows
Firewall, UAC, BitLocker, Windows Update, SmartScreen, LSA protection, Credential Guard,
audit logging; and any write under `HKCU` or another user's hive.

## HR-18 Output budget and privacy

The status line is at most 512 characters (Exit-WithCode truncates). It never contains
user names, e-mail addresses, file contents, or full user-profile paths. Counts and
identifiers only. Every Intune admin with read access sees this output.

## HR-19 Idempotent remediation

The remediation script re-evaluates state before changing anything. If the state is
already compliant it exits with the compliant token for its type (for example
`UP_TO_DATE`, `COMPLIANT`, `NOT_EXPOSED`) and changes nothing.

## HR-20 No reboots, no closing user apps

Scripts never restart the device (`Restart-Computer`, `shutdown.exe`, installer flags
that force a reboot) and never stop user-facing application processes. Use
`/norestart` and report `STAGED` or `PENDING_REBOOT`.

## HR-21 Fail safe

When the state cannot be established (source unreachable, winget missing, unparseable
version), detection reports `NOT_DETERMINED` and exits 0. It never triggers a remediation
it cannot complete. An unhandled exception in detection reports `ERROR` and exits 0; in
remediation it reports `ERROR` and exits 1.
