<#
Gate 2: generic Pester 5 test file. Runs one package script's main block against the
scenarios of its type/pattern matrix, with every side-effecting helper mocked.
Invoked by tools/pester/Invoke-Gate2.ps1 through a Pester container with data:
  PackagePath, Scenarios (from tools/pester/matrices/*.ps1). ASCII only.

How a scenario runs:
  1. The script is parsed (never executed as a file). All top-level statements except the
     final try (constants and helper functions) are dot-sourced into the test scope.
  2. Default mocks: Initialize-Log, Write-RemediationLog, Remove-SecureStagingDir, Write-Host, and
     Exit-WithCode -> throw "ExitCalled:<code>" (tools/pester/README.md).
  3. Scenario Setup runs, then scenario Mocks are applied.
  4. The main try/catch/finally runs, with any raw 'exit N' in the outer catch rewritten to
     throw "ExitCalled:N" so the test process is not terminated.
  Scenarios with WindowsOnly = $true are skipped off Windows and reported by Invoke-Gate2
  as PASS_PENDING_WINDOWS; they run inside the Gate 4 VM (Phase 3).
  5. Assertions: exactly one Exit-WithCode with the expected token and code (or, for the
     ERROR path, the outer catch's ERROR line), plus the scenario's own Assert block.
#>
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][object[]]$Scenarios
)

BeforeDiscovery {
    $script:cases = $Scenarios
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Mocks.ps1')
}

Describe 'Gate 2 package scenarios' {
    It '<Role>: <Name>' -ForEach $script:cases {
        if ($WindowsOnly -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'needs Windows-only cmdlet behaviour; runs in the Gate 4 VM'
            return
        }
        if (-not $IsWindows) {
            # Simulate the Windows environment variables the scripts read under SYSTEM.
            foreach ($kv in @(@('SystemRoot', 'C:\Windows'), @('ProgramData', 'C:\ProgramData'), @('ProgramFiles', 'C:\Program Files'), @('SystemDrive', 'C:'))) {
                if (-not [Environment]::GetEnvironmentVariable($kv[0])) { [Environment]::SetEnvironmentVariable($kv[0], $kv[1]) }
            }
            # Join-Path resolves the drive of 'C:\...' paths; map C: to a temp folder so path
            # building works. Nothing is written there: every file-system helper is mocked.
            if (-not (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name C -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -Scope Global
            }
        }
        $scriptPath = Join-Path $PackagePath ('{0}.ps1' -f $Role)
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $tk = $null
        $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tk, [ref]$er)
        $er.Count | Should -Be 0
        $stmts = @($ast.EndBlock.Statements)
        $mainAst = $stmts[-1]
        $mainAst | Should -BeOfType ([System.Management.Automation.Language.TryStatementAst])
        $defs = ($stmts[0..($stmts.Count - 2)] | ForEach-Object { $_.Extent.Text }) -join "`n"
        . ([scriptblock]::Create($defs))

        $global:G2 = @{}
        Mock Initialize-Log { }
        Mock Write-RemediationLog { }
        if (Get-Command Remove-SecureStagingDir -ErrorAction SilentlyContinue) { Mock Remove-SecureStagingDir { } }
        Mock Write-Host { $global:G2.host = "$Object" }
        Mock Exit-WithCode { throw ('ExitCalled:{0}' -f $Code) }

        if ($Setup) { . $Setup }
        if ($Mocks) {
            foreach ($k in $Mocks.Keys) { Mock -CommandName $k -MockWith $Mocks[$k] }
        }

        $mainText = [regex]::Replace($mainAst.Extent.Text, '(?m)^(\s*)exit\s+([01])\s*$', '$1throw "ExitCalled:$2"')
        $thrown = $null
        try { . ([scriptblock]::Create($mainText)) } catch { $thrown = $_.Exception.Message }

        if ($thrown -ne ('ExitCalled:{0}' -f $ExpectCode)) {
            # Evidence for the repair loop: what actually happened.
            throw ('expected {0} exit {1}; got "{2}"; outer-catch line: "{3}"' -f $ExpectToken, $ExpectCode, $thrown, $global:G2.host)
        }
        if ($ExpectToken -eq 'ERROR') {
            Should -Invoke Exit-WithCode -Times 0 -Exactly
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'ERROR | *' }
        } else {
            $tok = $ExpectToken
            $cod = $ExpectCode
            Should -Invoke Exit-WithCode -Times 1 -Exactly
            Should -Invoke Exit-WithCode -Times 1 -Exactly -ParameterFilter { $Token -eq $tok -and $Code -eq $cod }
        }
        if ($Assert) { . $Assert }
    }
}
