# Gate 2 matrix: app-update, Pattern B1 (vendor-direct installer). Returns the scenario list.
# Mock builders come from tools/pester/Mocks.ps1. $TARGET_VERSION comes from the package.

$installMocks = {
    @{
        'New-SecureStagingDir' = { 'C:\ProgramData\IntuneRemediation\Staging\x_1' }
        'Invoke-FileDownload'  = { }
        'Test-InstallerTrust'  = { New-TrustResult $true }
    }
}

function Join-Mocks($a, $b) { $h = @{}; foreach ($k in $a.Keys) { $h[$k] = $a[$k] }; foreach ($k in $b.Keys) { $h[$k] = $b[$k] }; return $h }

@(
    # ---------------- detection ----------------
    @{ Name = 'app absent'; Role = 'detect'; ExpectToken = 'NOT_INSTALLED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Absent' '' } } }
    @{ Name = 'user-scope install only (D2)'; Role = 'detect'; ExpectToken = 'SKIPPED_USER_SCOPE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'UserOnly' '' } } }
    @{ Name = 'installed version unreadable'; Role = 'detect'; ExpectToken = 'NOT_DETERMINED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Unreadable' '' } } }
    @{ Name = 'up to date'; Role = 'detect'; ExpectToken = 'UP_TO_DATE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Machine' '99.0.0.0' } } }
    @{ Name = 'outdated'; Role = 'detect'; ExpectToken = 'OUTDATED'; ExpectCode = 1
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Machine' '0.0.1.0' } } }
    @{ Name = 'unexpected exception exits 0'; Role = 'detect'; ExpectToken = 'ERROR'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { throw 'boom' } } }

    # ---------------- remediation ----------------
    @{ Name = 'app absent'; Role = 'remediate'; ExpectToken = 'NOT_INSTALLED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Absent' '' }; 'New-SecureStagingDir' = { throw 'must not be called' } }
       Assert = { Should -Invoke New-SecureStagingDir -Times 0 -Exactly } }
    @{ Name = 'user-scope install only (D2)'; Role = 'remediate'; ExpectToken = 'SKIPPED_USER_SCOPE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'UserOnly' '' } } }
    @{ Name = 'already current: no download'; Role = 'remediate'; ExpectToken = 'UP_TO_DATE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Machine' '99.0.0.0' }; 'Invoke-FileDownload' = { throw 'must not be called' } }
       Assert = { Should -Invoke Invoke-FileDownload -Times 0 -Exactly } }
    @{ Name = 'installer fails trust check: nothing installed'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { New-AppState 'Machine' '0.0.1.0' }
           'Test-InstallerTrust'       = { New-TrustResult $false 'signer mismatch CN="Evil" O="Evil"' }
           'Invoke-ProcessWithTimeout' = { throw 'must not be called' }
       })
       Assert = {
           Should -Invoke Invoke-ProcessWithTimeout -Times 0 -Exactly
           Should -Invoke Remove-SecureStagingDir -Times 1 -Exactly
       } }
    @{ Name = 'install succeeds and is verified'; Role = 'remediate'; ExpectToken = 'REMEDIATED'; ExpectCode = 0
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { if ((Step-G2Counter 'app') -eq 1) { New-AppState 'Machine' '0.0.1.0' } else { New-AppState 'Machine' '99.0.0.0' } }
           'Invoke-ProcessWithTimeout' = { New-ProcResult 0 }
       })
       Assert = {
           Should -Invoke Test-InstallerTrust -Times 1 -Exactly -ParameterFilter { $ExpectedSignerCN -eq $EXPECTED_SIGNER_CN -and $ExpectedSignerO -eq $EXPECTED_SIGNER_O }
           Should -Invoke Invoke-FileDownload -Times 1 -Exactly -ParameterFilter { $OutFile -like '*IntuneRemediation*Staging*x_1*' }
           Should -Invoke Remove-SecureStagingDir -Times 1 -Exactly
       } }
    @{ Name = 'installer exit 3010 without new version: pending reboot'; Role = 'remediate'; ExpectToken = 'PENDING_REBOOT'; ExpectCode = 0
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { New-AppState 'Machine' '0.0.1.0' }
           'Invoke-ProcessWithTimeout' = { New-ProcResult 3010 }
       }) }
    @{ Name = 'msiexec 3010 wins even when the exe already shows the new version (HR-13)'; Role = 'remediate'; ExpectToken = 'PENDING_REBOOT'; ExpectCode = 0
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { if ((Step-G2Counter 'app') -eq 1) { New-AppState 'Machine' '0.0.1.0' } else { New-AppState 'Machine' '99.0.0.0' } }
           'Invoke-ProcessWithTimeout' = { New-ProcResult 3010 }
       }) }
    @{ Name = 'installer fails'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { New-AppState 'Machine' '0.0.1.0' }
           'Invoke-ProcessWithTimeout' = { New-ProcResult 1603 }
       }) }
    @{ Name = 'installer exit 0 but version unchanged is not success'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion'   = { New-AppState 'Machine' '0.0.1.0' }
           'Invoke-ProcessWithTimeout' = { New-ProcResult 0 }
       }) }
    @{ Name = 'download throws: error path still cleans staging'; Role = 'remediate'; ExpectToken = 'ERROR'; ExpectCode = 1
       Mocks = (Join-Mocks (& $installMocks) @{
           'Get-InstalledAppVersion' = { New-AppState 'Machine' '0.0.1.0' }
           'Invoke-FileDownload'     = { throw 'network down' }
       })
       Assert = { Should -Invoke Remove-SecureStagingDir -Times 1 -Exactly } }
)
