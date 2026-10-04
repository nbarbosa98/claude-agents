<#
Unit tests for references/helpers.ps1 that run on any OS (macOS, Linux, Windows).
Windows-only behaviour (ACLs, registry, process kill) is in Helpers.Windows.Tests.ps1.
Run: Invoke-Pester tools/pester/helpers   (Pester 5). ASCII only.
#>
BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:HelpersPath = Join-Path $root '.claude/skills/intune-remediation/references/helpers.ps1'
    . $script:HelpersPath
    . (Join-Path $root 'tools/pester/Mocks.ps1')
    # Get-AuthenticodeSignature exists only on Windows; Pester can mock only existing commands.
    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        function global:Get-AuthenticodeSignature { param([string]$LiteralPath, [string]$FilePath) }
    }
    Mock Write-RemediationLog { }
}

Describe 'ConvertTo-NormalizedVersion' {
    It 'normalises <In> to <Out>' -ForEach @(
        @{ In = '1.2'; Out = '1.2.0.0' }
        @{ In = '1.2.3'; Out = '1.2.3.0' }
        @{ In = '129.0.6668.90'; Out = '129.0.6668.90' }
        @{ In = 'v24.08'; Out = '24.8.0.0' }
        @{ In = '7.4.2 (x64)'; Out = '7.4.2.0' }
    ) {
        (ConvertTo-NormalizedVersion $In).ToString() | Should -Be $Out
    }
    It 'returns null for <In>' -ForEach @(@{ In = '' }, @{ In = $null }, @{ In = 'abc' }, @{ In = '99999999999.1' }) {
        ConvertTo-NormalizedVersion $In | Should -BeNullOrEmpty
    }
    It 'makes 1.2 equal to 1.2.0 (plain [version] does not)' {
        ([version]'1.2' -lt [version]'1.2.0') | Should -BeTrue
        (ConvertTo-NormalizedVersion '1.2') -eq (ConvertTo-NormalizedVersion '1.2.0') | Should -BeTrue
    }
}

Describe 'Get-DnField' {
    It 'reads quoted and plain RDNs' {
        Get-DnField -Dn 'CN="Foo, Inc.", O=Foo Inc, C=US' -Field 'CN' | Should -Be 'Foo, Inc.'
        Get-DnField -Dn 'CN="Foo, Inc.", O=Foo Inc, C=US' -Field 'O' | Should -Be 'Foo Inc'
    }
    It 'does not confuse O with OU' {
        Get-DnField -Dn 'OU=Dept, CN=X' -Field 'O' | Should -Be ''
    }
}

Describe 'Invoke-Winget builds complete command lines' {
    BeforeEach { Mock Invoke-ProcessWithTimeout { New-ProcResult 0 } }
    It 'show-versions carries the required flags' {
        $null = Invoke-Winget -WingetPath 'w.exe' -Operation 'show-versions' -PackageId 'A.B' -TimeoutSeconds 60
        Should -Invoke Invoke-ProcessWithTimeout -Times 1 -Exactly -ParameterFilter {
            $a = $ArgumentList -join ' '
            $ArgumentList[0] -eq 'show' -and $a -like '*--id A.B*' -and $a -like '*--exact*' -and $a -like '*--source winget*' -and
            $a -like '*--accept-source-agreements*' -and $a -like '*--disable-interactivity*' -and $a -like '*--versions*' -and $TimeoutSeconds -eq 60
        }
    }
    It 'upgrade carries machine scope, silent and agreements; include-unknown only when asked' {
        $null = Invoke-Winget -WingetPath 'w.exe' -Operation 'upgrade' -PackageId 'A.B' -TimeoutSeconds 300
        Should -Invoke Invoke-ProcessWithTimeout -Times 1 -Exactly -ParameterFilter {
            $a = $ArgumentList -join ' '
            $ArgumentList[0] -eq 'upgrade' -and $a -like '*--scope machine*' -and $a -like '*--silent*' -and
            $a -like '*--accept-package-agreements*' -and $a -notlike '*--include-unknown*'
        }
        $null = Invoke-Winget -WingetPath 'w.exe' -Operation 'upgrade' -PackageId 'A.B' -TimeoutSeconds 300 -IncludeUnknown
        Should -Invoke Invoke-ProcessWithTimeout -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like '*--include-unknown*' }
    }
    It 'rejects package ids that could inject arguments' {
        { Invoke-Winget -WingetPath 'w.exe' -Operation 'upgrade' -PackageId 'A.B --override x' -TimeoutSeconds 1 } | Should -Throw
    }
}

Describe 'Get-WingetCatalogVersion is label-independent' {
    It 'picks the highest bare version from <Case> output' -ForEach @(
        @{ Case = 'English'; Out = "Found Example App [Example.App]`r`nVersion`r`n-------`r`n2.10.1`r`n2.9.0`r`n2.10.0`r`n" }
        @{ Case = 'German'; Out = "Gefunden Example App [Example.App]`r`nVersion`r`n-------`r`n2.10.1`r`n2.9.0`r`n" }
        @{ Case = 'Japanese-like header'; Out = "X [Example.App]`nY`n---`n2.10.1`n1.0`n" }
    ) {
        Mock Invoke-Winget { New-ProcResult 0 $false $Out }
        (Get-WingetCatalogVersion -WingetPath 'w' -PackageId 'Example.App' -TimeoutSeconds 60).ToString() | Should -Be '2.10.1.0'
    }
    It 'returns null on timeout' {
        Mock Invoke-Winget { New-ProcResult $null $true "2.0" }
        Get-WingetCatalogVersion -WingetPath 'w' -PackageId 'Example.App' -TimeoutSeconds 60 | Should -BeNullOrEmpty
    }
    It 'returns null on non-zero exit (package not found)' {
        Mock Invoke-Winget { New-ProcResult -1978335212 }
        Get-WingetCatalogVersion -WingetPath 'w' -PackageId 'Example.App' -TimeoutSeconds 60 | Should -BeNullOrEmpty
    }
    It 'ignores a header line that is only a version-like label' {
        Mock Invoke-Winget { New-ProcResult 0 $false "Found X [A.B]`nVersion`n-------`n3.0`n" }
        (Get-WingetCatalogVersion -WingetPath 'w' -PackageId 'A.B' -TimeoutSeconds 60).ToString() | Should -Be '3.0.0.0'
    }
}

Describe 'Get-InstalledAppVersion' {
    BeforeEach {
        Mock Get-MachineInstall { }
        Mock Get-UserScopeInstall { }
        Mock Test-Path { $false }
        Mock Get-FileVersionSafe { $null }
    }
    It 'Absent when nothing is found anywhere' {
        (Get-InstalledAppVersion -DisplayNamePattern 'X*' -MainExePaths @('p') -VersionSource 'FileVersion').Status | Should -Be 'Absent'
    }
    It 'UserOnly when only per-user installs exist' {
        Mock Get-UserScopeInstall { New-UserInstall }
        (Get-InstalledAppVersion -DisplayNamePattern 'X*' -MainExePaths @('p') -VersionSource 'FileVersion').Status | Should -Be 'UserOnly'
    }
    It 'Machine from the exe file version, preferred over DisplayVersion' {
        Mock Test-Path { $true }
        Mock Get-FileVersionSafe { [version]'2.0.0.5' }
        Mock Get-MachineInstall { New-MachineInstall 'X' '2.0' }
        $r = Get-InstalledAppVersion -DisplayNamePattern 'X*' -MainExePaths @('p') -VersionSource 'FileVersion'
        $r.Status | Should -Be 'Machine'
        $r.Version.ToString() | Should -Be '2.0.0.5'
    }
    It 'falls back to DisplayVersion when the file version is unreadable' {
        Mock Get-MachineInstall { New-MachineInstall 'X' '3.1' }
        $r = Get-InstalledAppVersion -DisplayNamePattern 'X*' -MainExePaths @('p') -VersionSource 'FileVersion'
        $r.Version.ToString() | Should -Be '3.1.0.0'
    }
    It 'takes the lowest of several machine entries (an outdated second copy counts)' {
        Mock Get-MachineInstall { New-MachineInstall 'X' '3.1'; New-MachineInstall 'X' '3.10' }
        (Get-InstalledAppVersion -DisplayNamePattern 'X*' -VersionSource 'DisplayVersion').Version.ToString() | Should -Be '3.1.0.0'
    }
    It 'takes the lowest file version when x64 and x86 copies are both present' {
        Mock Test-Path { $true }
        Mock Get-FileVersionSafe { if ($Path -like '*x86*') { [version]'24.9.0.0' } else { [version]'26.3.0.0' } }
        $r = Get-InstalledAppVersion -DisplayNamePattern 'X*' -MainExePaths @('C:\Program Files\X\x.exe', 'C:\Program Files (x86)\X\x.exe') -VersionSource 'FileVersion'
        $r.Version.ToString() | Should -Be '24.9.0.0'
    }
    It 'Unreadable when installed but no version parses' {
        Mock Get-MachineInstall { New-MachineInstall 'X' 'unknown' }
        (Get-InstalledAppVersion -DisplayNamePattern 'X*' -VersionSource 'DisplayVersion').Status | Should -Be 'Unreadable'
    }
    It 'does not look at user scope when a machine install exists' {
        Mock Get-MachineInstall { New-MachineInstall 'X' '1.0' }
        $null = Get-InstalledAppVersion -DisplayNamePattern 'X*' -VersionSource 'DisplayVersion'
        Should -Invoke Get-UserScopeInstall -Times 0 -Exactly
    }
}

Describe 'Test-InstallerTrust' {
    BeforeEach {
        Mock Test-Path { $true }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'ABC123' } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Vendor Ltd, O=Example Vendor Ltd, C=GB' } } }
    }
    It 'trusts a valid signature from the expected signer' {
        (Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'Example Vendor Ltd' -ExpectedSignerO 'Example Vendor Ltd').Trusted | Should -BeTrue
    }
    It 'checks SHA256 case-insensitively when published' {
        (Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'Example Vendor Ltd' -ExpectedSignerO 'Example Vendor Ltd' -ExpectedSha256 'abc123').Trusted | Should -BeTrue
    }
    It 'refuses a hash mismatch before looking at the signature' {
        $r = Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'Example Vendor Ltd' -ExpectedSignerO 'Example Vendor Ltd' -ExpectedSha256 'DEAD'
        $r.Trusted | Should -BeFalse
        $r.Reason | Should -Be 'SHA256 mismatch'
        Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
    }
    It 'refuses status <Status>' -ForEach @(@{ Status = 'NotSigned' }, @{ Status = 'HashMismatch' }, @{ Status = 'UnknownError' }) {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = $Status; SignerCertificate = $null } }
        (Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'Example Vendor Ltd' -ExpectedSignerO 'Example Vendor Ltd').Trusted | Should -BeFalse
    }
    It 'refuses a valid signature from another signer' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Vendor Ltd, O=Evil Corp' } } }
        $r = Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'Example Vendor Ltd' -ExpectedSignerO 'Example Vendor Ltd'
        $r.Trusted | Should -BeFalse
        $r.Reason | Should -BeLike 'signer mismatch*'
    }
    It 'refuses a missing file' {
        Mock Test-Path { $false }
        (Test-InstallerTrust -Path 'i.msi' -ExpectedSignerCN 'a' -ExpectedSignerO 'b').Reason | Should -Be 'installer missing'
    }
}

Describe 'Exit-WithCode (child process: exit cannot run inside Pester)' {
    BeforeAll {
        $script:RunExit = {
            param($Token, $Message, $Code)
            $cmd = ". '{0}'; Exit-WithCode -Token '{1}' -Message '{2}' -Code {3}" -f $script:HelpersPath, $Token, $Message.Replace("'", "''"), $Code
            $out = & pwsh -NoProfile -NonInteractive -Command $cmd
            return @{ Out = @($out); Exit = $LASTEXITCODE }
        }
    }
    It 'writes one status line and exits with the code' {
        $r = & $script:RunExit 'UP_TO_DATE' 'Example 1.0 is up to date' 0
        $r.Exit | Should -Be 0
        $r.Out.Count | Should -Be 1
        $r.Out[0] | Should -Be 'UP_TO_DATE | Example 1.0 is up to date'
        (& $script:RunExit 'OUTDATED' 'x' 1).Exit | Should -Be 1
    }
    It 'replaces non-ASCII and control characters' {
        $r = & $script:RunExit 'FAILED' ("caf" + [char]0x00E9 + "`tx") 1
        $r.Out[0] | Should -Be 'FAILED | caf? x'
    }
    It 'truncates to 512 characters' {
        $r = & $script:RunExit 'FAILED' ('a' * 1000) 1
        $r.Out[0].Length | Should -Be 512
        $r.Out[0] | Should -BeLike '*...'
    }
    It 'rejects a lowercase token' {
        (& $script:RunExit 'bad' 'x' 0).Exit | Should -Not -Be 0
    }
}
