    if (-not (Test-Path -LiteralPath $PLUGIN_DIR)) {
        Exit-WithCode -Token 'AUDIT_CLEAN' -Message ('{0} audit clean: pluginDir=absent;legacy=0' -f $SUBJECT) -Code 0
    }
    $items = @(Get-ChildItem -LiteralPath $PLUGIN_DIR -Filter $LEGACY_PATTERN -File -ErrorAction Stop)
    Write-Log -Message ('Legacy plugins found: {0}' -f $items.Count)
    if ($items.Count -gt 0) {
        Exit-WithCode -Token 'AUDIT_FINDING' -Message ('{0} audit finding: pluginDir=present;legacy={1}' -f $SUBJECT, $items.Count) -Code 1
    }
    Exit-WithCode -Token 'AUDIT_CLEAN' -Message ('{0} audit clean: pluginDir=present;legacy=0' -f $SUBJECT) -Code 0
