<#
Windows-only helper tests: real ACLs, registry, processes. Skipped on other OSes; run in
the Gate 4 VM as an administrator (Phase 3). Tag: Windows. ASCII only.
These create and delete only paths under C:\ProgramData\IntuneRemediation\Staging and
under $TestDrive.
#>
BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    . (Join-Path $root '.claude/skills/intune-remediation/references/helpers.ps1')
    if ($IsWindows) { Mock Write-Log { } }
}

Describe 'Windows helpers' -Tag 'Windows' -Skip:(-not $IsWindows) {
    Context 'New-SecureStagingDir / Remove-SecureStagingDir' {
        It 'creates a dir with inheritance off and only SYSTEM and Administrators' {
            $d = New-SecureStagingDir -PackageId 'test-pkg'
            try {
                Test-TrustedAcl -Path $d | Should -Be ''
                $acl = Get-Acl -LiteralPath $d
                $acl.AreAccessRulesProtected | Should -BeTrue
                $sids = $acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique
                $sids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
            } finally { Remove-SecureStagingDir -Path $d }
            Test-Path -LiteralPath $d | Should -BeFalse
        }
        It 'refuses to delete outside the staging root' {
            $victim = Join-Path $TestDrive 'keep'
            $null = New-Item -ItemType Directory -Path $victim
            Remove-SecureStagingDir -Path $victim
            Test-Path -LiteralPath $victim | Should -BeTrue
        }
        It 'reports an untrusted ACL' {
            $d = Join-Path $TestDrive 'open'
            $null = New-Item -ItemType Directory -Path $d
            Test-TrustedAcl -Path $d | Should -Not -Be ''
        }
    }
    Context 'Invoke-ProcessWithTimeout' {
        It 'returns the exit code of a finished process' {
            $r = Invoke-ProcessWithTimeout -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', 'exit 7') -TimeoutSeconds 30
            $r.TimedOut | Should -BeFalse
            $r.ExitCode | Should -Be 7
        }
        It 'kills a process that exceeds the timeout' {
            $r = Invoke-ProcessWithTimeout -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -ArgumentList @('-n', '30', '127.0.0.1') -TimeoutSeconds 2
            $r.TimedOut | Should -BeTrue
            Get-Process -Name ping -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
        It 'captures stdout' {
            $r = Invoke-ProcessWithTimeout -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', 'echo hello') -TimeoutSeconds 30 -CaptureOutput
            $r.StdOut.Trim() | Should -Be 'hello'
        }
    }
    Context 'Registry discovery' {
        It 'reads both HKLM Uninstall views without error' {
            { Get-MachineInstalls -DisplayNamePattern '*' } | Should -Not -Throw
        }
        It 'lists user-scope installs without loading hives' {
            { Get-UserScopeInstalls -DisplayNamePattern 'NoSuchApp*' -RelativeExePaths @('AppData\Local\NoSuchApp\x.exe') } | Should -Not -Throw
        }
    }
}
