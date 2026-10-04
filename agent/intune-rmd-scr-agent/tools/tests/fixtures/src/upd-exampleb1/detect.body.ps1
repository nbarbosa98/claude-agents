    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    $target = ConvertTo-NormalizedVersion $TARGET_VERSION
    if ($app.Status -eq 'Unreadable' -or $null -eq $target) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: version unreadable' -f $SUBJECT) -Code 0
    }
    if ($app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    Exit-WithCode -Token 'OUTDATED' -Message ('{0} {1} is outdated. Target {2}' -f $SUBJECT, $app.Version, $target) -Code 1
