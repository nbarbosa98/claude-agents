    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    Write-RemediationLog -Message ('Install status {0}, version {1}' -f $app.Status, $app.Version)
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    $winget = Get-WingetPath
    if (-not $winget) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to catalog failed: winget not found' -f $SUBJECT) -Code 1
    }
    $target = Get-WingetCatalogVersion -WingetPath $winget -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_CATALOG
    if ($null -eq $target) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to catalog failed: catalog version unavailable' -f $SUBJECT) -Code 1
    }
    if ($app.Status -eq 'Machine' -and $app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade' -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_UPGRADE -IncludeUnknown:$INCLUDE_UNKNOWN
    Write-RemediationLog -Message ('winget upgrade exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
    $after = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    if ($after.Status -eq 'Machine' -and $after.Version -ge $target) {
        Exit-WithCode -Token 'REMEDIATED' -Message ('{0} updated to {1}' -f $SUBJECT, $after.Version) -Code 0
    }
    if ($r.ExitCode -eq $WINGET_REBOOT_TO_FINISH) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    if ($r.TimedOut) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: winget timed out' -f $SUBJECT, $target) -Code 1
    }
    Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: winget exit {2}, installed {3}' -f $SUBJECT, $target, $r.ExitCode, $after.Version) -Code 1
