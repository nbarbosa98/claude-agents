<#
Package:   __PACKAGE_ID__
Type:      __SCRIPT_TYPE__
Role:      detect
Contract:  __CONTRACT_VERSION__
Generated: __GENERATOR_ID__
Summary:   __ONE_LINE_SUMMARY__
#>

# ===== Constants (HR-04: every timeout is declared here; sum <= 540 s) =====
$PACKAGE_ID = '__PACKAGE_ID__'
$SUBJECT    = '__SUBJECT__'
__TYPE_CONSTANTS__

# ===== Helpers (copied verbatim from references/helpers.ps1) =====
__HELPERS__

# ===== Main =====
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'detect'
    Write-RemediationLog -Message ('Start detect. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

__DETECT_BODY__
}
catch {
    if ($_.Exception.Message -like 'ExitCalled:*') { throw }
    $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace '[^\x20-\x7E]', '?')
    Write-RemediationLog -Level 'ERROR' -Message ('Unhandled: ' + $reason)
    Write-Host ('ERROR | {0} script error: {1}' -f $SUBJECT, $reason)
    exit 0
}
