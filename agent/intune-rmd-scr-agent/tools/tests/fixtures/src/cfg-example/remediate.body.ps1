    $failing = @($DESIRED | Where-Object { -not (Test-DesiredStateEntry -Entry $_) })
    if ($failing.Count -eq 0) {
        Exit-WithCode -Token 'COMPLIANT' -Message ('{0} compliant' -f $SUBJECT) -Code 0
    }
    foreach ($e in $failing) {
        Set-DesiredStateEntry -Entry $e
    }
    $still = @($DESIRED | Where-Object { -not (Test-DesiredStateEntry -Entry $_) })
    if ($still.Count -gt 0) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} change failed: {1} setting(s) still drifted' -f $SUBJECT, $still.Count) -Code 1
    }
    if ($REBOOT_REQUIRED) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    Exit-WithCode -Token 'REMEDIATED' -Message ('{0} remediated: {1} setting(s) corrected' -f $SUBJECT, $failing.Count) -Code 0
