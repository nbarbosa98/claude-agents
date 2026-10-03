# Type: app-update

Keeps a third-party Windows app at or above a target version, machine scope only.
Package id prefix: `upd-`. The classifier's decision record chooses the pattern and holds
the evidence; the generator never picks a pattern itself.

## Patterns

| Pattern | Use when (from evidence) | Target version source | Install mechanism |
|---|---|---|---|
| A | App is in the winget community source with a machine-scope installer | `Get-WingetCatalogVersion` at run time | `Invoke-Winget -Operation upgrade` |
| Browser | Chrome, Edge, Firefox and other self-updating browsers | Vendor discovery endpoint or pinned minimum in the decision record | Vendor enterprise MSI into secure staging |
| B1 | Not in winget, vendor offers a direct machine-wide installer | Vendor discovery endpoint (vendor-probe evidence) | Download into secure staging, trust check, silent install |
| B2 | Parallel release lines by design (Node.js LTS lines, Python 3.x) | Latest patch within each installed line | Per-line installer; never cross a line |
| B3 | Side-by-side majors (.NET runtimes) | Latest patch per installed major | Per-major installer; never remove another major |

Microsoft 365 Apps (Click-to-Run) is out of scope: refuse and point to update channels.

## Constants (all patterns)

```powershell
$DISPLAY_NAME_LIKE   = '__DISPLAY_NAME_LIKE__'   # -like pattern for HKLM DisplayName
$MAIN_EXE_PATHS      = @('__MAIN_EXE_PATH__')     # absolute machine-scope paths, from evidence
$USER_EXE_RELPATHS   = @('__USER_EXE_RELPATH__')  # relative to a profile root, for D2 detection
$VERSION_SOURCE      = '__VERSION_SOURCE__'       # 'FileVersion' or 'DisplayVersion' (decision record)
$TIMEOUT_CATALOG     = 60                         # seconds
```

Pattern A adds `$WINGET_ID`, `$INCLUDE_UNKNOWN` (`$true`/`$false`, same literal in both
scripts), `$TIMEOUT_UPGRADE`, and in remediation the winget exit code it checks:
`$WINGET_REBOOT_TO_FINISH = -1978334967` (0x8A150109, "Restart your PC to finish
installation"; microsoft/winget-cli returnCodes.md). Download patterns add `$TARGET_VERSION`
or a discovery source, `$DOWNLOAD_URL`, `$EXPECTED_SIGNER_CN`, `$EXPECTED_SIGNER_O`,
`$EXPECTED_SHA256` (empty when the vendor publishes none), `$TIMEOUT_DOWNLOAD`,
`$TIMEOUT_INSTALL`.

## Worked examples (read these first)

Complete, gate-tested bodies live in the Gate 1/2 test fixtures:

| Pattern | Source (constants + bodies) | Composed scripts |
|---|---|---|
| A | `tools/tests/fixtures/src/upd-example/` | `tools/tests/fixtures/packages/upd-example/` |
| B1 | `tools/tests/fixtures/src/upd-exampleb1/` | `tools/tests/fixtures/packages/upd-exampleb1/` |

They pass Gate 1 and the Gate 2 matrices in `tools/pester/matrices/app-update-A.ps1` and
`app-update-B1.ps1`. Follow their structure; adapt only what the decision record changes.

## Installed version (all patterns)

Always call the shared helper, in detection and in remediation (HR-12, FM-13):

```powershell
    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
```

`$app.Status` is `Machine`, `UserOnly`, `Absent` or `Unreadable`; `$app.Version` is a
normalised `[version]` or `$null`. Map them as follows:

| Status | Detection | Remediation |
|---|---|---|
| `UserOnly` | `SKIPPED_USER_SCOPE`, 0 | `SKIPPED_USER_SCOPE`, 0 |
| `Absent` | `NOT_INSTALLED`, 0 | `NOT_INSTALLED`, 0 |
| `Unreadable` | `NOT_DETERMINED`, 0 (or treated as outdated when `$INCLUDE_UNKNOWN = $true`, Pattern A only) | continue to install; the post-check decides |
| `Machine` | compare with the target | re-check (HR-19), then install and post-check |

## Pattern A detection

After the status mapping: `Get-WingetPath` (missing: `NOT_DETERMINED`, 0), then
`Get-WingetCatalogVersion` (null: `NOT_DETERMINED`, 0), then `UP_TO_DATE` (installed >= target,
exit 0) or `OUTDATED` (exit 1). See `upd-example/detect.body.ps1`.

## Pattern A remediation

After the status mapping: winget missing or catalog unavailable is `FAILED`, 1; installed
>= target is `UP_TO_DATE`, 0 with no upgrade; otherwise
`Invoke-Winget -Operation 'upgrade' ... -IncludeUnknown:$INCLUDE_UNKNOWN`, then call
`Get-InstalledAppVersion` again (post-check, HR-13). Order matters: first, the reboot code
(`$WINGET_REBOOT_TO_FINISH`; msiexec 3010 for MSI patterns) is `PENDING_REBOOT`, 0, even
when the main exe already shows the new version, because other files can still be waiting
for replacement at reboot. Only then is a post-check at or above the target `REMEDIATED`.
Everything else, including winget exit 0 with an unchanged version, is `FAILED`, 1. See
`upd-example/remediate.body.ps1`.

## Browser pattern

- Remediation never calls `winget upgrade` and never runs `winget source update` (HR-15).
- The installer is the vendor's enterprise MSI, downloaded into secure staging, trust
  checked, then `msiexec.exe /i <msi> /qn /norestart /l*v <staging>\msi.log`.
- A running browser may keep the old binaries in use. The "staged" indicator (for
  example a pending new executable next to the old one) is vendor-specific and must be
  recorded with evidence in the decision record; until it is lab-verified per vendor it
  is **UNVERIFIED**. When the indicator is present and the on-disk version is still old:
  `STAGED`, exit 0 (HR-13). Never close the browser (HR-20).

## B1 / B2 / B3

- B1: same flow as Browser without the staged state; use `STAGED` only if the vendor
  documents one.
- B2: detection evaluates each installed release line separately; a line is outdated
  only against the latest patch of the same line. Remediation updates each outdated line
  and never installs a new line.
- B3: as B2 per major version; never removes a major, never installs a missing one.

## Evidence the decision record must hold

Pattern, winget id or vendor endpoint, target version source, `VERSION_SOURCE`,
main exe paths, SHA256 availability, scope support, and the source URL for each field.
Expected signer CN and O: required for download patterns (Browser, B1-B3: HR-08); for
Pattern A optional, recorded when evidence is available, so `/drift` can notice a vendor
certificate change. See decision-record.md.

`displayNameLike` must be as narrow as the evidence allows: anchor it on the exact display
name format the installer writes (for example `7-Zip [0-9]*` for "7-Zip <version>"), so
forks and similarly named products (for example "7-Zip ZS") never match. PowerShell `-like`
supports character ranges such as `[0-9]`.
