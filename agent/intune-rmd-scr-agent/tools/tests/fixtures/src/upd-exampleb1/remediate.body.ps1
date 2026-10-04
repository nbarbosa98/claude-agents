    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    $target = ConvertTo-NormalizedVersion $TARGET_VERSION
    if ($app.Status -eq 'Machine' -and $app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    $stagingDir = New-SecureStagingDir -PackageId $PACKAGE_ID
    $msi = Join-Path $stagingDir 'installer.msi'
    Invoke-FileDownload -Uri $DOWNLOAD_URL -OutFile (Join-Path $stagingDir 'installer.msi') -TimeoutSeconds $TIMEOUT_DOWNLOAD
    $trust = Test-InstallerTrust -Path $msi -ExpectedSignerCN $EXPECTED_SIGNER_CN -ExpectedSignerO $EXPECTED_SIGNER_O -ExpectedSha256 $EXPECTED_SHA256
    if (-not $trust.Trusted) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: {2}' -f $SUBJECT, $target, $trust.Reason) -Code 1
    }
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $msiLog = Join-Path $stagingDir 'msi.log'
    $r = Invoke-ProcessWithTimeout -FilePath $msiexec -ArgumentList @('/i', ('"{0}"' -f $msi), '/qn', '/norestart', '/l*v', ('"{0}"' -f $msiLog)) -TimeoutSeconds $TIMEOUT_INSTALL
    Write-RemediationLog -Message ('msiexec exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
    $after = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    # HR-13: msiexec 3010 (restart required) is not a verified fix, whatever the exe shows.
    if ($r.ExitCode -eq 3010) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    if ($after.Status -eq 'Machine' -and $after.Version -ge $target) {
        Exit-WithCode -Token 'REMEDIATED' -Message ('{0} updated to {1}' -f $SUBJECT, $after.Version) -Code 0
    }
    Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: msiexec exit {2}' -f $SUBJECT, $target, $r.ExitCode) -Code 1
