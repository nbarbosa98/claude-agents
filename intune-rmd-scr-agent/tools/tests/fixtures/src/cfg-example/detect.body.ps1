    $drift = New-Object System.Collections.ArrayList
    foreach ($e in $DESIRED) {
        if (-not (Test-DesiredStateEntry -Entry $e)) { $null = $drift.Add($e.Name) }
    }
    if ($drift.Count -eq 0) {
        Exit-WithCode -Token 'COMPLIANT' -Message ('{0} compliant' -f $SUBJECT) -Code 0
    }
    Write-Log -Message ('Drifted: ' + ($drift -join ', '))
    Exit-WithCode -Token 'DRIFTED' -Message ('{0} drifted: {1} setting(s): {2}' -f $SUBJECT, $drift.Count, ($drift -join ', ')) -Code 1
