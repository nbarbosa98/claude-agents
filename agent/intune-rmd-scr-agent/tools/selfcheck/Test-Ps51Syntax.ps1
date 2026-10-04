<#
Parses PowerShell files and reports parse errors and PowerShell-7-only syntax (HR-11).
Runs under pwsh 7 (the parser accepts 7 syntax, so 7-only nodes are detected in the AST).
Output: JSON array of findings. Exit 1 if any finding.
Usage: pwsh -NoProfile -File tools/selfcheck/Test-Ps51Syntax.ps1 -Path <file> [-Path <file> ...]
#>
param([Parameter(Mandatory = $true)][string[]]$Path)
$findings = New-Object System.Collections.ArrayList
foreach ($p in $Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $p).Path, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        $null = $findings.Add([pscustomobject]@{ rule_id = 'PARSE'; file = $p; line = $e.Extent.StartLineNumber; evidence = $e.Message })
    }
    $checks = @(
        @{ Id = 'HR-11-ternary'; Test = { param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] } },
        @{ Id = 'HR-11-pipeline-chain'; Test = { param($n) $n -is [System.Management.Automation.Language.PipelineChainAst] } },
        @{ Id = 'HR-11-null-coalescing'; Test = { param($n) ($n -is [System.Management.Automation.Language.BinaryExpressionAst]) -and ($n.Operator -eq 'QuestionQuestion') } },
        @{ Id = 'HR-11-null-coalescing-assign'; Test = { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Operator -eq 'QuestionQuestionEquals') } },
        @{ Id = 'HR-11-null-conditional'; Test = { param($n) ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional) -or ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.NullConditional) } }
    )
    foreach ($c in $checks) {
        $hits = $ast.FindAll($c.Test, $true)
        foreach ($h in $hits) {
            $null = $findings.Add([pscustomobject]@{ rule_id = $c.Id; file = $p; line = $h.Extent.StartLineNumber; evidence = $h.Extent.Text })
        }
    }
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $name = $cmd.GetCommandName()
        $params = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        if ($name -eq 'ForEach-Object' -and $params -contains 'Parallel') {
            $null = $findings.Add([pscustomobject]@{ rule_id = 'HR-11-parallel'; file = $p; line = $cmd.Extent.StartLineNumber; evidence = $cmd.Extent.Text })
        }
        if ($name -eq 'ConvertFrom-Json' -and $params -contains 'AsHashtable') {
            $null = $findings.Add([pscustomobject]@{ rule_id = 'HR-11-ashashtable'; file = $p; line = $cmd.Extent.StartLineNumber; evidence = $cmd.Extent.Text })
        }
    }
}
ConvertTo-Json -InputObject @($findings) -Depth 3
if ($findings.Count -gt 0) { exit 1 }
exit 0
