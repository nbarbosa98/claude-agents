<#
Tests for tools/vm/Gate4.psm1 using the in-process fake VM (no Azure, no Windows).
Run: Invoke-Pester tools/vm/tests   (Pester 5, PowerShell 7). ASCII only.
#>
BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $root 'tools/vm/Gate4.psm1') -Force
    . (Join-Path $PSScriptRoot 'FakeBackend.ps1')
    $script:Fix = Join-Path $root 'tools/tests/fixtures/packages'
    $script:Catalog = { param($id) '2.0' }
    function Invoke-Fake([string]$Pkg, [hashtable]$FakeArgs, [string[]]$Only = @(), [switch]$WinTests) {
        $be = New-FakeGateBackend @FakeArgs
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $r = Invoke-Gate4 -PackagePath (Join-Path $script:Fix $Pkg) -Backend $be -OutDir $out -Only $Only -CatalogLookup $script:Catalog -IncludeWindowsTests:$WinTests
        return @{ result = $r; backend = $be; out = $out }
    }
}

Describe 'Gate 4 on a well-behaved VM' {
    It 'Pattern A: every scenario passes, tampered-installer is not applicable' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A' }
        $x.result.status | Should -Be 'PASS'
        ($x.result.scenarios | Where-Object name -eq 'tampered-installer').status | Should -Be 'NOT_APPLICABLE'
        @($x.result.scenarios | Where-Object { $_.status -eq 'PASS' }).Count | Should -Be 4
        $x.result.target | Should -Be '2.0.0.0'
        Test-Path (Join-Path $x.out 'gate4.json') | Should -BeTrue
    }
    It 'reverts before every scenario' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A' }
        @($x.backend.State.calls | Where-Object { $_ -eq 'Reset' }).Count | Should -Be 4
    }
    It 'B1: tampered installer fails safely and leaves the version unchanged' {
        $x = Invoke-Fake 'upd-exampleb1' @{ Kind = 'B1'; Target = '5.2.0.0'; Outdated = '5.1.0.0'; PackageId = 'upd-exampleb1' }
        $x.result.status | Should -Be 'PASS'
        $t = $x.result.scenarios | Where-Object name -eq 'tampered-installer'
        $t.status | Should -Be 'PASS'
        ($t.steps | Where-Object role -eq 'remediate-tampered').token | Should -Be 'FAILED'
    }
    It 'stages a tampered copy whose expected signer differs and the real remediation unchanged' {
        $x = Invoke-Fake 'upd-exampleb1' @{ Kind = 'B1'; Target = '5.2.0.0'; Outdated = '5.1.0.0'; PackageId = 'upd-exampleb1' } -Only @('tampered-installer')
        $x.backend.State.payload['remediate-tampered.ps1'] | Should -Match "EXPECTED_SIGNER_O  = 'Gate4 Tampered Signer'"
        $orig = Get-Content (Join-Path $script:Fix 'upd-exampleb1/remediate.ps1') -Raw
        $x.backend.State.payload['remediate.ps1'] | Should -Be $orig
    }
    It 'config-change: drift is corrected and the registry value checked' {
        $x = Invoke-Fake 'cfg-example' @{ Kind = 'cfg'; PackageId = 'cfg-example' }
        $x.result.status | Should -Be 'PASS'
        @($x.result.scenarios).Count | Should -Be 2
    }
    It 'fetches results larger than one Run Command output in chunks' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A' } -Only @('absent')
        $x.result.environment.edition | Should -Be 'Enterprise'
        @($x.backend.State.calls | Where-Object { $_ -eq 'Fetch' }).Count | Should -BeGreaterThan 0
    }
    It 'runs the Windows helper tests when asked' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A' } -Only @('absent') -WinTests
        ($x.result.scenarios | Where-Object name -eq 'windows-helper-tests').status | Should -Be 'PASS'
        $x.backend.State.payload.Keys | Should -Contain 'tests/Helpers.Windows.Tests.ps1'
    }
}

Describe 'Gate 4 catches broken behaviour' {
    It 'REMEDIATED without a new version on disk fails main' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ noVersionChange = $true } } -Only @('main')
        $x.result.status | Should -Be 'FAIL'
        $m = $x.result.scenarios[0]
        @($m.assertions | Where-Object { -not $_.pass } | ForEach-Object name) | Should -Contain 'on-disk FileVersion >= target'
    }
    It 'a leftover staging dir fails' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ leaveStaging = $true } } -Only @('main')
        @($x.result.scenarios[0].assertions | Where-Object { -not $_.pass } | ForEach-Object name) | Should -Contain 'no staging dir left'
    }
    It 'extra stdout lines fail the single-status-line check' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ extraOutput = $true } } -Only @('absent')
        $x.result.status | Should -Be 'FAIL'
    }
    It 'a run that is not SYSTEM fails' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ notSystem = $true } } -Only @('absent')
        @($x.result.scenarios[0].assertions | Where-Object { -not $_.pass } | ForEach-Object name) | Should -Contain 'ran as SYSTEM in 64-bit PowerShell'
    }
    It 'a run over the 540 s budget fails' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ slow = $true } } -Only @('absent')
        @($x.result.scenarios[0].assertions | Where-Object { -not $_.pass } | ForEach-Object name) | Should -Contain 'each run <= 540 s'
    }
    It 'a failed revert is an error, never a pass' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ resetFails = $true } } -Only @('absent')
        $x.result.status | Should -Be 'FAIL'
        $x.result.scenarios[0].status | Should -Be 'ERROR'
    }
}

Describe 'Gate 4 never over-reports' {
    It 'no user profile makes user-scope-only NOT_RUN and the gate INCOMPLETE' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; Faults = @{ noProfile = $true } } -Only @('user-scope-only')
        $x.result.scenarios[0].status | Should -Be 'NOT_RUN'
        $x.result.status | Should -Be 'INCOMPLETE'
    }
    It 'a backend that cannot revert is INCOMPLETE even when every check passes' {
        $x = Invoke-Fake 'upd-example' @{ Kind = 'A'; CanRevert = $false } -Only @('absent')
        $x.result.scenarios[0].status | Should -Be 'PASS'
        $x.result.status | Should -Be 'INCOMPLETE'
    }
}

Describe 'Spec and helpers' {
    It 'rejects a gate4.json whose packageId does not match' {
        $d = Join-Path $TestDrive 'upd-x'
        $null = New-Item -ItemType Directory -Path $d
        '{"packageId":"upd-y","scenarios":["main"]}' | Set-Content (Join-Path $d 'gate4.json')
        { Read-Gate4Spec -PackagePath $d } | Should -Throw '*packageId*'
    }
    It 'rejects a url install without sha256' {
        $d = Join-Path $TestDrive 'upd-z'
        $null = New-Item -ItemType Directory -Path $d
        '{"packageId":"upd-z","scenarios":["main"],"outdatedInstall":{"method":"url","url":"https://x/a.msi"}}' | Set-Content (Join-Path $d 'gate4.json')
        { Read-Gate4Spec -PackagePath $d } | Should -Throw '*sha256*'
    }
    It 'Get-StatusLine finds exactly one contract-shaped line' {
        (Get-StatusLine "OUTDATED | x 1.0 is outdated").token | Should -Be 'OUTDATED'
        (Get-StatusLine "noise`nOUTDATED | x").lines | Should -Be 2
        (Get-StatusLine "outdated | x").statusLines | Should -Be 0
    }
}
