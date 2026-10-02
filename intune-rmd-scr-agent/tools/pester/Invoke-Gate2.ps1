<#
Gate 2 runner: selects the scenario matrix for a package's type and pattern, checks that
every status token the scripts can emit is covered by at least one scenario, runs
tools/pester/Package.Tests.ps1, and prints a JSON result. ASCII only.

Usage: pwsh -NoProfile -File tools/pester/Invoke-Gate2.ps1 -PackagePath <dir> [-OutFile <json>]
Exit: 0 PASS, 1 FAIL, 2 PASS_PENDING_WINDOWS (Windows-only scenarios skipped), 3 usage/environment error.

Matrix lookup: tools/pester/matrices/<type>-<pattern>.ps1, else <type>.ps1. Extra
package-specific scenarios may live in <package>/src/tests/*.scenarios.ps1 and are appended.
#>
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pkg = (Resolve-Path -LiteralPath $PackagePath).Path
$result = [ordered]@{ gate = 'gate2'; package = (Split-Path -Leaf $pkg); status = 'FAIL'; platform = $(if ($IsWindows) { 'windows' } else { 'non-windows' }); matrix = $null; passed = 0; failed = 0; skipped = 0; uncovered = @(); undercovered = @(); failures = @() }

function Write-Result {
    $json = $result | ConvertTo-Json -Depth 6
    if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $json -Encoding ascii }
    $json
}

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { [Console]::Error.WriteLine('Pester 5 is not installed'); exit 3 }
Import-Module $pester.Path -Force

$dr = Get-Content -LiteralPath (Join-Path $pkg 'decision-record.json') -Raw | ConvertFrom-Json
$type = [string]$dr.type
$pattern = [string]$dr.pattern
$candidates = @()
if ($pattern) { $candidates += (Join-Path $PSScriptRoot ('matrices/{0}-{1}.ps1' -f $type, $pattern)) }
$candidates += (Join-Path $PSScriptRoot ('matrices/{0}.ps1' -f $type))
$matrix = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $matrix) {
    $result.failures += @{ scenario = '(matrix)'; message = ('no Gate 2 matrix for type {0} pattern {1}' -f $type, $pattern) }
    Write-Result
    exit 1
}
$result.matrix = [System.IO.Path]::GetRelativePath($root, $matrix)
$scenarios = @(& $matrix)
foreach ($extra in @(Get-ChildItem -LiteralPath (Join-Path $pkg 'src/tests') -Filter '*.scenarios.ps1' -File -ErrorAction SilentlyContinue)) {
    $scenarios += @(& $extra.FullName)
}

# ---- coverage: every token each script emits, plus ERROR, needs a scenario ----
$facts = Join-Path $root 'tools/lint/Get-ScriptFacts.ps1'
foreach ($role in @('detect', 'remediate')) {
    $sp = Join-Path $pkg ('{0}.ps1' -f $role)
    if (-not (Test-Path -LiteralPath $sp)) { continue }
    $fx = & pwsh -NoProfile -NonInteractive -File $facts -Path $sp | ConvertFrom-Json
    $sites = @{}
    foreach ($c in $fx.commands) {
        if ($c.name -eq 'Exit-WithCode' -and -not $c.function -and $c.params.Token.kind -eq 'literal') {
            $t = [string]$c.params.Token.value
            $sites[$t] = 1 + [int]$sites[$t]
        }
    }
    $sites['ERROR'] = 1
    foreach ($t in $sites.Keys) {
        $n = @($scenarios | Where-Object { $_.Role -eq $role -and $_.ExpectToken -eq $t }).Count
        if ($n -eq 0) { $result.uncovered += ('{0}:{1}' -f $role, $t) }
        elseif ($n -lt $sites[$t]) { $result.undercovered += ('{0}:{1} ({2} call sites, {3} scenarios)' -f $role, $t, $sites[$t], $n) }
    }
}

# ---- run ----
$container = New-PesterContainer -Path (Join-Path $PSScriptRoot 'Package.Tests.ps1') -Data @{ PackagePath = $pkg; Scenarios = $scenarios }
$cfg = New-PesterConfiguration
$cfg.Run.Container = $container
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
$run = Invoke-Pester -Configuration $cfg
$result.passed = $run.PassedCount
$result.failed = $run.FailedCount
$result.skipped = $run.SkippedCount
foreach ($t in $run.Failed) {
    $msg = ''
    if ($t.ErrorRecord) { $msg = ($t.ErrorRecord | Select-Object -First 1).Exception.Message }
    $result.failures += @{ scenario = $t.ExpandedName; message = $msg }
}
if ($run.FailedCount -eq 0 -and $run.PassedCount -gt 0 -and $result.uncovered.Count -eq 0) {
    # Skipped (Windows-only) scenarios have not run: not deliverable until they pass in the VM.
    if ($run.SkippedCount -gt 0) { $result.status = 'PASS_PENDING_WINDOWS' } else { $result.status = 'PASS' }
}
Write-Result
if ($result.status -eq 'PASS') { exit 0 }
if ($result.status -eq 'PASS_PENDING_WINDOWS') { exit 2 }
exit 1
