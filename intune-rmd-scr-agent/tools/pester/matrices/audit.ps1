# Gate 2 matrix: audit (detection only). Returns the scenario list.
# Audit packages differ in what they read, so this generic matrix only fixes the exit
# paths; each audit package adds <package>/tests/*.scenarios.ps1 with the mocks for its
# own data source. The scenarios below fit the aud-example fixture (file-system audit).
# Get-ChildItem -File is a FileSystem-provider dynamic parameter that Pester cannot mock
# for Windows paths on macOS/Linux, so those scenarios are WindowsOnly (run in the VM).

@(
    @{ Name = 'source absent: clean'; Role = 'detect'; ExpectToken = 'AUDIT_CLEAN'; ExpectCode = 0
       Mocks = @{ 'Test-Path' = { $false } } }
    @{ Name = 'present, nothing found: clean'; Role = 'detect'; ExpectToken = 'AUDIT_CLEAN'; ExpectCode = 0; WindowsOnly = $true
       Mocks = @{ 'Test-Path' = { $true }; 'Get-ChildItem' = { } } }
    @{ Name = 'finding present'; Role = 'detect'; ExpectToken = 'AUDIT_FINDING'; ExpectCode = 1; WindowsOnly = $true
       Mocks = @{ 'Test-Path' = { $true }; 'Get-ChildItem' = { 'a'; 'b' } }
       Assert = { Should -Invoke Exit-WithCode -Times 1 -Exactly -ParameterFilter { $Message -like '*legacy=2*' } } }
    @{ Name = 'read error exits 0'; Role = 'detect'; ExpectToken = 'ERROR'; ExpectCode = 0; WindowsOnly = $true
       Mocks = @{ 'Test-Path' = { $true }; 'Get-ChildItem' = { throw 'access denied' } } }
)
