<#
Gate 1 helper: parses one PowerShell file with the PowerShell AST and prints JSON facts
that tools/lint/lint.py evaluates. It never executes the script.

Usage: pwsh -NoProfile -File tools/lint/Get-ScriptFacts.ps1 -Path <file.ps1>
Runs on PowerShell 7 (macOS, Linux, Windows). ASCII only.
#>
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
$full = (Resolve-Path -LiteralPath $Path).Path
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
$A = [System.Management.Automation.Language.Ast]

# ---- outer try: the last top-level try statement of the script ----
$topStatements = @()
if ($ast.EndBlock) { $topStatements = @($ast.EndBlock.Statements) }
$outerTry = $null
foreach ($s in $topStatements) {
    if ($s -is [System.Management.Automation.Language.TryStatementAst]) { $outerTry = $s }
}
$catchExtents = @()
$finallyExtent = $null
if ($outerTry) {
    foreach ($c in $outerTry.CatchClauses) { $catchExtents += $c.Body.Extent }
    if ($outerTry.Finally) { $finallyExtent = $outerTry.Finally.Extent }
}

function Test-Within($node, $extent) {
    if ($null -eq $extent) { return $false }
    return ($node.Extent.StartOffset -ge $extent.StartOffset -and $node.Extent.EndOffset -le $extent.EndOffset)
}
function Get-EnclosingFunction($node) {
    $p = $node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
        $p = $p.Parent
    }
    return $null
}
function Test-InLoop($node) {
    $p = $node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
        if ($p -is [System.Management.Automation.Language.LoopStatementAst]) { return $true }
        if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $cmd = $p.Parent
            if ($cmd -is [System.Management.Automation.Language.CommandAst]) {
                $n = $cmd.GetCommandName()
                if ($n -in @('ForEach-Object', 'Where-Object', '%', 'foreach')) { return $true }
            }
        }
        $p = $p.Parent
    }
    return $false
}
function Get-ArgValue($a) {
    if ($null -eq $a) { return @{ kind = 'none'; value = $null; text = '' } }
    if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ kind = 'literal'; value = $a.Value; text = $a.Extent.Text } }
    if ($a -is [System.Management.Automation.Language.ConstantExpressionAst]) { return @{ kind = 'literal'; value = $a.Value; text = $a.Extent.Text } }
    if ($a -is [System.Management.Automation.Language.VariableExpressionAst]) { return @{ kind = 'variable'; value = $a.VariablePath.UserPath; text = $a.Extent.Text } }
    return @{ kind = 'expression'; value = $null; text = $a.Extent.Text }
}
function Get-Loc($node) {
    return @{
        line          = $node.Extent.StartLineNumber
        function      = (Get-EnclosingFunction $node)
        inOuterCatch  = [bool](@($catchExtents | Where-Object { Test-Within $node $_ }).Count)
        inFinally     = (Test-Within $node $finallyExtent)
        inLoop        = (Test-InLoop $node)
    }
}

$out = [ordered]@{
    file         = $Path
    parseErrors  = @()
    ps7Syntax    = @()
    functions    = @()
    topLevel     = @()
    commands     = @()
    exits        = @()
    methodCalls  = @()
    envVars      = @()
    assignments  = @()
    strings      = @()
    outerTry     = $null
}

foreach ($e in $errors) { $out.parseErrors += @{ line = $e.Extent.StartLineNumber; message = $e.Message } }

# ---- PowerShell 7-only syntax (HR-11) ----
$ps7 = @(
    @{ Id = 'ternary'; T = { param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] } },
    @{ Id = 'pipeline-chain'; T = { param($n) $n -is [System.Management.Automation.Language.PipelineChainAst] } },
    @{ Id = 'null-coalescing'; T = { param($n) ($n -is [System.Management.Automation.Language.BinaryExpressionAst]) -and ($n.Operator -eq 'QuestionQuestion') } },
    @{ Id = 'null-coalescing-assign'; T = { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Operator -eq 'QuestionQuestionEquals') } },
    @{ Id = 'null-conditional'; T = { param($n) (($n -is [System.Management.Automation.Language.MemberExpressionAst]) -or ($n -is [System.Management.Automation.Language.IndexExpressionAst])) -and $n.NullConditional } }
)
foreach ($c in $ps7) {
    foreach ($h in $ast.FindAll($c.T, $true)) { $out.ps7Syntax += @{ id = $c.Id; line = $h.Extent.StartLineNumber; text = $h.Extent.Text } }
}

# ---- functions ----
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $out.functions += @{ name = $f.Name; startLine = $f.Extent.StartLineNumber; endLine = $f.Extent.EndLineNumber; text = $f.Extent.Text; topLevel = ($f.Parent -eq $ast.EndBlock) }
}

# ---- top-level statement kinds, for section order ----
foreach ($s in $topStatements) {
    $kind = 'other'
    if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $kind = 'function' }
    elseif ($s -is [System.Management.Automation.Language.AssignmentStatementAst]) { $kind = 'assignment' }
    elseif ($s -is [System.Management.Automation.Language.TryStatementAst]) { $kind = 'try' }
    $out.topLevel += @{ kind = $kind; line = $s.Extent.StartLineNumber; text = ($s.Extent.Text -split "`n")[0] }
}

# ---- commands with parameters ----
foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $cmd.GetCommandName()
    $params = @{}
    $positional = @()
    $els = @($cmd.CommandElements)
    $i = 1
    while ($i -lt $els.Count) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($el.Argument) {
                $params[$el.ParameterName] = Get-ArgValue $el.Argument
            } elseif (($i + 1) -lt $els.Count -and -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) {
                $params[$el.ParameterName] = Get-ArgValue $els[$i + 1]
                $i++
            } else {
                $params[$el.ParameterName] = @{ kind = 'switch'; value = $true; text = '' }
            }
        } else {
            $positional += (Get-ArgValue $el)
        }
        $i++
    }
    $loc = Get-Loc $cmd
    $out.commands += @{
        name = $name; invocation = [string]$cmd.InvocationOperator; text = $cmd.Extent.Text
        params = $params; positional = $positional
        line = $loc.line; function = $loc.function; inOuterCatch = $loc.inOuterCatch; inFinally = $loc.inFinally; inLoop = $loc.inLoop
    }
}

# ---- exit statements ----
foreach ($x in $ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.ExitStatementAst]) }, $true)) {
    $loc = Get-Loc $x
    $val = $null
    if ($x.Pipeline) { $val = $x.Pipeline.Extent.Text }
    $out.exits += @{ line = $loc.line; function = $loc.function; inOuterCatch = $loc.inOuterCatch; value = $val }
}

# ---- method calls (WaitForExit, Console writes) ----
foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $loc = Get-Loc $m
    $argc = 0
    if ($m.Arguments) { $argc = @($m.Arguments).Count }
    $out.methodCalls += @{ member = $m.Member.Extent.Text; target = $m.Expression.Extent.Text; argCount = $argc; line = $loc.line; function = $loc.function }
}

# ---- environment variables ----
foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    if ($v.VariablePath.DriveName -eq 'env') {
        $loc = Get-Loc $v
        $out.envVars += @{ name = $v.VariablePath.UserPath.Substring(4); line = $loc.line; function = $loc.function }
    }
}

# ---- top-level assignments (constants) ----
foreach ($s in $topStatements) {
    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $lhs = $s.Left
        $name = $null
        if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) { $name = $lhs.VariablePath.UserPath }
        $lit = $null
        $kind = 'expression'
        $rhs = $s.Right
        if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $e = $rhs.Expression
            if ($e -is [System.Management.Automation.Language.ConstantExpressionAst]) { $lit = $e.Value; $kind = 'literal' }
            elseif ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.VariablePath.UserPath -in @('true', 'false')) {
                $lit = ($e.VariablePath.UserPath -eq 'true'); $kind = 'literal'
            }
        }
        $out.assignments += @{ name = $name; kind = $kind; value = $lit; line = $s.Extent.StartLineNumber; text = $s.Extent.Text }
    }
}

# ---- string constants (for path and text checks) ----
foreach ($sc in $ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true)) {
    $loc = Get-Loc $sc
    $out.strings += @{ value = $sc.Value; line = $loc.line; function = $loc.function; inOuterCatch = $loc.inOuterCatch }
}

# ---- outer try details ----
if ($outerTry) {
    $firstTry = $null
    if ($outerTry.Body.Statements.Count -gt 0) { $firstTry = $outerTry.Body.Statements[0].Extent.Text }
    $firstCatch = $null
    if ($outerTry.CatchClauses.Count -gt 0 -and $outerTry.CatchClauses[0].Body.Statements.Count -gt 0) {
        $firstCatch = $outerTry.CatchClauses[0].Body.Statements[0].Extent.Text
    }
    $fin = $null
    if ($outerTry.Finally) { $fin = $outerTry.Finally.Extent.Text }
    $out.outerTry = @{ line = $outerTry.Extent.StartLineNumber; catchCount = $outerTry.CatchClauses.Count; firstTryStatement = $firstTry; firstCatchStatement = $firstCatch; finallyText = $fin }
}

$out | ConvertTo-Json -Depth 8 -Compress
