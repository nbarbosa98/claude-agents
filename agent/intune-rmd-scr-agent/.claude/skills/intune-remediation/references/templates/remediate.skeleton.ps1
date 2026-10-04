<#
Package:   __PACKAGE_ID__
Type:      __SCRIPT_TYPE__
Role:      remediate
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
$stagingDir = $null
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'remediate'
    Write-RemediationLog -Message ('Start remediate. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

    # HR-19: re-check state first; exit with the compliant token if nothing to do.
__REMEDIATE_BODY__
}
catch {
    if ($_.Exception.Message -like 'ExitCalled:*') { throw }
    $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace '[^\x20-\x7E]', '?')
    Write-RemediationLog -Level 'ERROR' -Message ('Unhandled: ' + $reason)
    Write-Host ('ERROR | {0} script error: {1}' -f $SUBJECT, $reason)
    exit 1
}
finally {
    Remove-SecureStagingDir -Path $stagingDir
}
