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

Pattern A adds `$WINGET_ID`, `$INCLUDE_UNKNOWN` (`$true`/`$false`, same value in both
scripts), `$TIMEOUT_UPGRADE`. Download patterns add `$DOWNLOAD_URL` (or a discovery URL),
`$EXPECTED_SIGNER_CN`, `$EXPECTED_SIGNER_O`, `$EXPECTED_SHA256` (empty when the vendor
publishes none), `$TIMEOUT_DOWNLOAD`, `$TIMEOUT_INSTALL`.

## Installed-version routine (all patterns)

```powershell
    $machine = Get-MachineInstalls -DisplayNamePattern $DISPLAY_NAME_LIKE
    $installed = $null
    if ($VERSION_SOURCE -eq 'FileVersion') {
        foreach ($p in $MAIN_EXE_PATHS) {
            $v = Get-FileVersionSafe -Path $p
            if ($v -and (($null -eq $installed) -or ($v -gt $installed))) { $installed = $v }
        }
    }
    if ($null -eq $installed) {
        foreach ($m in $machine) {
            $v = ConvertTo-NormalizedVersion $m.DisplayVersion
            if ($v -and (($null -eq $installed) -or ($v -gt $installed))) { $installed = $v }
        }
    }
    if ($machine.Count -eq 0 -and $null -eq $installed) {
        $user = Get-UserScopeInstalls -DisplayNamePattern $DISPLAY_NAME_LIKE -RelativeExePaths $USER_EXE_RELPATHS
        if ($user.Count -gt 0) {
            Write-Log -Message ('User-scope installs only: {0}' -f $user.Count)
            Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
        }
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    if ($null -eq $installed) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: installed version unreadable' -f $SUBJECT) -Code 0
    }
```

With `$INCLUDE_UNKNOWN = $true` (Pattern A only), an installed-but-unreadable version is
treated as outdated instead of `NOT_DETERMINED`, and remediation passes `-IncludeUnknown`.

## Pattern A detection body

```powershell
    # (installed-version routine above)
    $winget = Get-WingetPath
    if (-not $winget) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: winget not found' -f $SUBJECT) -Code 0
    }
    $target = Get-WingetCatalogVersion -WingetPath $winget -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_CATALOG
    if ($null -eq $target) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: catalog version unavailable' -f $SUBJECT) -Code 0
    }
    Write-Log -Message ('Installed {0}, catalog {1}' -f $installed, $target)
    if ($installed -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $installed) -Code 0
    }
    Exit-WithCode -Token 'OUTDATED' -Message ('{0} {1} is outdated. Target {2}' -f $SUBJECT, $installed, $target) -Code 1
```

## Pattern A remediation body

```powershell
    # (installed-version routine above; HR-19 re-check)
    $winget = Get-WingetPath
    if (-not $winget) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to catalog failed: winget not found' -f $SUBJECT) -Code 1
    }
    $target = Get-WingetCatalogVersion -WingetPath $winget -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_CATALOG
    if ($target -and $installed -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $installed) -Code 0
    }
    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade' -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_UPGRADE -IncludeUnknown:$INCLUDE_UNKNOWN
    Write-Log -Message ('winget upgrade exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
    # Post-check (HR-13): re-read the installed version; never trust the exit code alone.
    # (installed-version routine again, into $after)
    if ($after -and $target -and $after -ge $target) {
        Exit-WithCode -Token 'REMEDIATED' -Message ('{0} updated to {1}' -f $SUBJECT, $after) -Code 0
    }
    if ($r.ExitCode -eq $WINGET_REBOOT_TO_FINISH) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: winget exit {2}' -f $SUBJECT, $target, $r.ExitCode) -Code 1
```

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
main exe paths, expected signer CN and O, SHA256 availability, scope support, and the
source URL for each field. See decision-record.md.
