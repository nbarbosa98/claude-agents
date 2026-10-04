# Gate 2 matrix: config-change (desired state). Returns the scenario list.
# Test-DesiredStateEntry / Set-DesiredStateEntry are mocked; the package's $DESIRED list is used as is.

@(
    # ---------------- detection ----------------
    @{ Name = 'all entries compliant'; Role = 'detect'; ExpectToken = 'COMPLIANT'; ExpectCode = 0
       Mocks = @{ 'Test-DesiredStateEntry' = { $true } } }
    @{ Name = 'one entry drifted'; Role = 'detect'; ExpectToken = 'DRIFTED'; ExpectCode = 1
       Mocks = @{ 'Test-DesiredStateEntry' = { (Step-G2Counter 't') -ne 1 } }
       Assert = { Should -Invoke Test-DesiredStateEntry -Times (@($DESIRED).Count) -Exactly } }
    @{ Name = 'unexpected exception exits 0'; Role = 'detect'; ExpectToken = 'ERROR'; ExpectCode = 0
       Mocks = @{ 'Test-DesiredStateEntry' = { throw 'registry exploded' } } }

    # ---------------- remediation ----------------
    @{ Name = 'already compliant: idempotent, nothing written'; Role = 'remediate'; ExpectToken = 'COMPLIANT'; ExpectCode = 0
       Mocks = @{ 'Test-DesiredStateEntry' = { $true }; 'Set-DesiredStateEntry' = { throw 'must not be called' } }
       Assert = { Should -Invoke Set-DesiredStateEntry -Times 0 -Exactly } }
    @{ Name = 'drift corrected and verified'; Role = 'remediate'; ExpectToken = 'REMEDIATED'; ExpectCode = 0
       Setup = { $global:G2.fixed = $false }
       Mocks = @{
           'Test-DesiredStateEntry' = { [bool]$global:G2.fixed }
           'Set-DesiredStateEntry'  = { $global:G2.fixed = $true }
       }
       Assert = { Should -Invoke Set-DesiredStateEntry -Times (@($DESIRED).Count) -Exactly } }
    @{ Name = 'drift corrected, reboot required'; Role = 'remediate'; ExpectToken = 'PENDING_REBOOT'; ExpectCode = 0
       Setup = { $global:G2.fixed = $false; $REBOOT_REQUIRED = $true }
       Mocks = @{
           'Test-DesiredStateEntry' = { [bool]$global:G2.fixed }
           'Set-DesiredStateEntry'  = { $global:G2.fixed = $true }
       } }
    @{ Name = 'write does not stick: failed'; Role = 'remediate'; ExpectToken = 'FAILED'; ExpectCode = 1
       Mocks = @{ 'Test-DesiredStateEntry' = { $false }; 'Set-DesiredStateEntry' = { } } }
    @{ Name = 'write throws: exits 1'; Role = 'remediate'; ExpectToken = 'ERROR'; ExpectCode = 1
       Mocks = @{ 'Test-DesiredStateEntry' = { $false }; 'Set-DesiredStateEntry' = { throw 'access denied' } } }
)
