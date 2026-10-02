# Gate 2 matrix: app-update, Pattern A (winget). Returns the scenario list.
# Each scenario: Name, Role, ExpectToken, ExpectCode, optional Setup, Mocks, Assert.
# Versions are [version] objects, as ConvertTo-NormalizedVersion returns them.

# Mock builders (New-AppState, New-ProcResult, Step-G2Counter) come from tools/pester/Mocks.ps1.

@(
    # ---------------- detection ----------------
    @{ Name = 'app absent'; Role = 'detect'; ExpectToken = 'NOT_INSTALLED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Absent' '' }; 'Get-WingetPath' = { throw 'must not be called' } }
       Assert = { Should -Invoke Get-WingetPath -Times 0 -Exactly } }
    @{ Name = 'user-scope install only (D2)'; Role = 'detect'; ExpectToken = 'SKIPPED_USER_SCOPE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'UserOnly' '' } } }
    @{ Name = 'installed version unreadable'; Role = 'detect'; ExpectToken = 'NOT_DETERMINED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Unreadable' '' } } }
    @{ Name = 'unknown version with INCLUDE_UNKNOWN is outdated'; Role = 'detect'; ExpectToken = 'OUTDATED'; ExpectCode = 1
       Setup = { $INCLUDE_UNKNOWN = $true }
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Unreadable' '' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
       } }
    @{ Name = 'winget missing fails open'; Role = 'detect'; ExpectToken = 'NOT_DETERMINED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Machine' '1.0.0.0' }; 'Get-WingetPath' = { $null } } }
    @{ Name = 'winget hang: catalog lookup times out'; Role = 'detect'; ExpectToken = 'NOT_DETERMINED'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion' = { New-AppState 'Machine' '1.0.0.0' }
           'Get-WingetPath'          = { 'C:\wa\winget.exe' }
           'Invoke-Winget'           = { New-ProcResult $null $true }
       }
       Assert = { Should -Invoke Invoke-Winget -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq $TIMEOUT_CATALOG } } }
    @{ Name = 'up to date'; Role = 'detect'; ExpectToken = 'UP_TO_DATE'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '2.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
       } }
    @{ Name = 'newer than catalog counts as up to date'; Role = 'detect'; ExpectToken = 'UP_TO_DATE'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '2.1.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
       } }
    @{ Name = 'outdated'; Role = 'detect'; ExpectToken = 'OUTDATED'; ExpectCode = 1
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '1.9.9.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
       } }
    @{ Name = 'unexpected exception exits 0'; Role = 'detect'; ExpectToken = 'ERROR'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { throw 'registry exploded' } } }

    # ---------------- remediation ----------------
    @{ Name = 'app absent'; Role = 'remediate'; ExpectToken = 'NOT_INSTALLED'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Absent' '' } } }
    @{ Name = 'user-scope install only (D2)'; Role = 'remediate'; ExpectToken = 'SKIPPED_USER_SCOPE'; ExpectCode = 0
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'UserOnly' '' }; 'Get-WingetPath' = { throw 'must not be called' } }
       Assert = { Should -Invoke Get-WingetPath -Times 0 -Exactly } }
    @{ Name = 'already current: idempotent, no upgrade'; Role = 'remediate'; ExpectToken = 'UP_TO_DATE'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '2.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
           'Invoke-Winget'            = { throw 'must not be called' }
       } }
    @{ Name = 'winget missing'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = @{ 'Get-InstalledAppVersion' = { New-AppState 'Machine' '1.0.0.0' }; 'Get-WingetPath' = { $null } } }
    @{ Name = 'catalog unavailable'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '1.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { $null }
       } }
    @{ Name = 'upgrade succeeds and is verified'; Role = 'remediate'; ExpectToken = 'REMEDIATED'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion'  = { if ((Step-G2Counter 'app') -eq 1) { New-AppState 'Machine' '1.0.0.0' } else { New-AppState 'Machine' '2.0.0.0' } }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
           'Invoke-Winget'            = { New-ProcResult 0 }
       }
       Assert = {
           Should -Invoke Invoke-Winget -Times 1 -Exactly -ParameterFilter { $Operation -eq 'upgrade' -and $PackageId -eq $WINGET_ID -and $IncludeUnknown -eq $INCLUDE_UNKNOWN }
           Should -Invoke Get-InstalledAppVersion -Times 2 -Exactly
       } }
    @{ Name = 'winget exit 0 but version unchanged is not success'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '1.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
           'Invoke-Winget'            = { New-ProcResult 0 }
       } }
    @{ Name = 'reboot required to finish'; Role = 'remediate'; ExpectToken = 'PENDING_REBOOT'; ExpectCode = 0
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '1.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
           'Invoke-Winget'            = { New-ProcResult -1978334967 }
       } }
    @{ Name = 'upgrade times out'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = @{
           'Get-InstalledAppVersion'  = { New-AppState 'Machine' '1.0.0.0' }
           'Get-WingetPath'           = { 'C:\wa\winget.exe' }
           'Get-WingetCatalogVersion' = { [version]'2.0.0.0' }
           'Invoke-Winget'            = { New-ProcResult $null $true }
       } }
    @{ Name = 'unexpected exception exits 1'; Role = 'remediate'; ExpectToken = 'ERROR'; ExpectCode = 1
       Mocks = @{ 'Get-InstalledAppVersion' = { throw 'registry exploded' } }
       Assert = { Should -Invoke Remove-SecureStagingDir -Times 1 -Exactly } }
)
