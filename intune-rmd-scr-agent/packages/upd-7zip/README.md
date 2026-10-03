# upd-7zip

## Summary

Keeps machine-scope 7-Zip at the current winget community catalog version.
Request (verbatim): "keep 7-Zip up to date".

Detection reads the installed version from the FileVersion of `7zFM.exe` (through the shared
`Get-InstalledAppVersion`) and compares it with the catalog version of `7zip.7zip` read at
run time. Remediation runs `winget upgrade` for `7zip.7zip` at machine scope and reports
`REMEDIATED` only after a post-check finds the catalog version on disk.

## Type and pattern

app-update, Pattern A (winget), as set in `decision-record.json` (confidence medium, no open
questions). The generator did not choose the pattern.

## Evidence

All values come from `decision-record.json`; sources are recorded there.

| Constant | Value | Source |
|---|---|---|
| `$WINGET_ID` | `7zip.7zip` | microsoft/winget-pkgs @5805efb1ae `manifests/7/7zip/7zip/26.03/7zip.7zip.installer.yaml` |
| Scope | machine for all installers (exe and wix); every installer has InstallerSha256 | same manifest |
| `$DISPLAY_NAME_LIKE` | `7-Zip*` | ip7z/7zip@26.03 `C/Util/7zipInstall/7zipInstall.c` (DisplayName '7-Zip ' + version + arch), `DOC/7zip.wxs` (Product Name '7-Zip ' + version + CPU) |
| `$MAIN_EXE_PATHS` | `C:\Program Files\7-Zip\7zFM.exe`, `C:\Program Files (x86)\7-Zip\7zFM.exe` | winget manifest DefaultInstallLocation; vendor installer sources (7zFM.exe) |
| `$USER_EXE_RELPATHS` | empty | Owner approval 2026-10-03 ("Accepted"): no documented per-user install folder |
| `$VERSION_SOURCE` | `FileVersion` | ip7z/7zip@26.03 `C/7zVersion.h`, `C/7zVersion.rc`: FILEVERSION 26,3,0,0 normalises equal to catalog '26.03' |
| `$INCLUDE_UNKNOWN` | `$false` (both scripts) | decision record `install.includeUnknown` |
| `$WINGET_REBOOT_TO_FINISH` | -1978334967 (0x8A150109) | microsoft/winget-cli `returnCodes.md` (references/sources.md) |
| Expected signer | not recorded; not used by Pattern A (winget verifies InstallerSha256) | decision record |

## Status tokens

| Script | Token | Exit | When |
|---|---|---|---|
| detect | `NOT_INSTALLED` | 0 | no machine or user-scope install found |
| detect | `SKIPPED_USER_SCOPE` | 0 | only per-user installs found (loaded HKU hives) |
| detect | `NOT_DETERMINED` | 0 | installed version unreadable, winget not found, or catalog version unavailable |
| detect | `UP_TO_DATE` | 0 | installed >= catalog |
| detect | `OUTDATED` | 1 | installed < catalog |
| detect | `ERROR` | 0 | unhandled exception (outer catch) |
| remediate | `NOT_INSTALLED` | 0 | app gone since detection |
| remediate | `SKIPPED_USER_SCOPE` | 0 | only per-user installs found |
| remediate | `UP_TO_DATE` | 0 | already compliant on re-check (HR-19); nothing changed |
| remediate | `REMEDIATED` | 0 | post-check finds machine install >= catalog |
| remediate | `PENDING_REBOOT` | 0 | winget returned 0x8A150109 and the post-check is still below target |
| remediate | `FAILED` | 1 | winget missing, catalog unavailable, timeout, or post-check below target |
| remediate | `ERROR` | 1 | unhandled exception (outer catch) |

## Intune settings

| Setting | Value | Why |
|---|---|---|
| Detection script | `detect.ps1` | |
| Remediation script | `remediate.ps1` | |
| Run this script using the logged-on credentials | No (runs as SYSTEM) | Machine-scope changes (ADR-009) |
| Enforce script signature check | No (v1, D5) | ADR-012 |
| Run script in 64-bit PowerShell | Yes | Native registry and Program Files views (ADR-009) |
| Schedule | Daily (proposed for app-update) | Confirmed during /deploy setup |
| Pilot group | named during /deploy | ADR-007 |
| Broad group | named during /deploy | ADR-007 |

## Time budget

| Script | Timeouts | Sum |
|---|---|---|
| detect | `$TIMEOUT_CATALOG` 60 s | 60 s |
| remediate | `$TIMEOUT_CATALOG` 60 s + `$TIMEOUT_UPGRADE` 300 s | 360 s |

Both are under the 540 s design ceiling (HR-04).

## Known failure modes

- FM-01 winget not found under SYSTEM: detect `NOT_DETERMINED`, remediate `FAILED`.
- FM-02 winget fails to start under SYSTEM (unsupported context, ADR-016): `FAILED ... winget exit <code>`.
- FM-03 catalog version unavailable (network, source agreement, proxy): detect `NOT_DETERMINED`.
- FM-04 version format mismatch: mitigated by FileVersion (26,3,0,0 vs catalog 26.03, both 26.3.0.0).
- FM-05 per-user install only: `SKIPPED_USER_SCOPE` when found in a loaded hive; see UNVERIFIED items.
- FM-09 timeout of the upgrade (300 s): `FAILED ... winget timed out`.
- FM-12 pending reboot never clears: repeated `PENDING_REBOOT`.
- FM-13 recurrence: both scripts use the same `Get-InstalledAppVersion` call and constants.
- FM-14 registry view mismatch: package must run 64-bit.

## Rollback

The package only upgrades 7-Zip in place through winget; it never uninstalls. To stop it,
unassign or delete the remediation in Intune. To return a device to an older 7-Zip, install
the wanted version manually (for example `winget install --id 7zip.7zip --exact --version <v>
--scope machine`) after the remediation is unassigned, otherwise the next run upgrades it again.

## UNVERIFIED items

- winget under SYSTEM is unsupported by Microsoft (ADR-016); `Get-WingetPath` behaviour and
  `winget show --versions` output shape (ADR-019) are to be confirmed in Gate 4.
- Gate 4 `blocked-endpoint` omitted: no recorded fact names the host(s) the winget community
  source uses, so `blockHosts` cannot be filled without guessing.
- Gate 4 `user-scope-only` omitted: `userExeRelPaths` is empty by owner approval (no documented
  per-user install folder), so there is no supported `relPath` to plant a copy at.
- Per-user MSI installs (ALLUSERS=2 in `DOC/7zip.wxs`) are expected to be found only through
  the loaded-hive HKU uninstall scan while that user is signed in (owner-accepted inference).
  A per-user-only copy of a signed-out user reports `NOT_INSTALLED`; nothing is changed
  either way.
- `$DISPLAY_NAME_LIKE = '7-Zip*'` also matches any other product whose DisplayName starts with
  "7-Zip" (for example third-party forks). If such a product is installed without `7zFM.exe`
  at the listed paths, `Get-InstalledAppVersion` falls back to that entry's registry
  DisplayVersion and compares it with the 7zip.7zip catalog version; not checked against
  real fork installs.
- When both an x64 and an x86 copy exist, `Get-InstalledAppVersion` takes the highest
  FileVersion of the listed paths, so an outdated second copy is not reported; `winget
  upgrade` acts on one installed entry only.
- Gate 4 `main`: winget is assumed to select the x64 installer on the x64 lab VM, so the
  version check uses `C:\Program Files\7-Zip\7zFM.exe`. The outdated install uses catalog
  version 24.09 (present in winget-pkgs @5805efb1ae per orchestrator-verified listing);
  that this older manifest still installs at machine scope is not checked.
- 7-Zip in use (open 7zFM.exe or shell extension loaded) during upgrade: installer behaviour
  (file-in-use, reboot code) not verified; would surface as `PENDING_REBOOT` or `FAILED`.
