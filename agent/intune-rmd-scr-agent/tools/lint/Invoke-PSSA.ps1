<#
Gate 1: runs PSScriptAnalyzer with the committed settings file and prints JSON findings.
Exit 3 when the PSScriptAnalyzer module is not installed (lint.py then reports
status PASS_PENDING_PSSA, which is not deliverable). ASCII only.

Usage: pwsh -NoProfile -File tools/lint/Invoke-PSSA.ps1 <file.ps1> [<file.ps1> ...]
#>
$files = @($args)
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    [Console]::Error.WriteLine('PSScriptAnalyzer module not installed')
    exit 3
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$all = @()
foreach ($f in $files) {
    $all += @(Invoke-ScriptAnalyzer -Path $f -Settings $settings | ForEach-Object {
        [pscustomobject]@{
            RuleName   = $_.RuleName
            Severity   = [string]$_.Severity
            ScriptPath = $_.ScriptPath
            Line       = $_.Line
            Message    = $_.Message
        }
    })
}
ConvertTo-Json -InputObject @($all) -Depth 3
exit 0
