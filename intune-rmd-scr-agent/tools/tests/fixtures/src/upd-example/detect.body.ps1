    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    Write-RemediationLog -Message ('Install status {0}, version {1}' -f $app.Status, $app.Version)
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Unreadable' -and -not $INCLUDE_UNKNOWN) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: installed version unreadable' -f $SUBJECT) -Code 0
    }
    $winget = Get-WingetPath
    if (-not $winget) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: winget not found' -f $SUBJECT) -Code 0
    }
    $target = Get-WingetCatalogVersion -WingetPath $winget -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_CATALOG
    if ($null -eq $target) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: catalog version unavailable' -f $SUBJECT) -Code 0
    }
    Write-RemediationLog -Message ('Installed {0}, catalog {1}' -f $app.Version, $target)
    if ($app.Status -eq 'Unreadable') {
        Exit-WithCode -Token 'OUTDATED' -Message ('{0} unknown version is treated as outdated. Target {1}' -f $SUBJECT, $target) -Code 1
    }
    if ($app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    Exit-WithCode -Token 'OUTDATED' -Message ('{0} {1} is outdated. Target {2}' -f $SUBJECT, $app.Version, $target) -Code 1
