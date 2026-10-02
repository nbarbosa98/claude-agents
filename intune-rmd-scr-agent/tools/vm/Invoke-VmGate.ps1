<#
Gate 4 entry point (PowerShell 7 on the operator's Mac, or Windows).

  pwsh -NoProfile -File tools/vm/Invoke-VmGate.ps1 -PackagePath packages/<id> [-Backend azure|local]
       [-Only main,absent] [-IncludeWindowsTests] [-OutDir out/<id>/gate4-x]

Reads vm settings from config/local.json (git-ignored). Writes <OutDir>/gate4.json and the
stdout of every run. Exit: 0 PASS, 1 FAIL/ERROR, 2 INCOMPLETE (not deliverable), 3 usage.
Lab VM only. ASCII only.
#>
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [ValidateSet('azure', 'local')][string]$Backend = 'azure',
    [string[]]$Only = @(),
    [switch]$IncludeWindowsTests,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'Gate4.psm1') -Force

$cfgPath = Join-Path $root 'config/local.json'
$be = $null
if ($Backend -eq 'azure') {
    if (-not (Test-Path -LiteralPath $cfgPath)) { [Console]::Error.WriteLine('config/local.json missing (copy config/example.json)'); exit 3 }
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    . (Join-Path $PSScriptRoot 'backends/Azure.ps1')
    $be = New-AzureGateBackend -VmConfig $cfg.vm
} else {
    . (Join-Path $PSScriptRoot 'backends/Local.ps1')
    $be = New-LocalGateBackend
}
$r = Invoke-Gate4 -PackagePath $PackagePath -Backend $be -Only $Only -IncludeWindowsTests:$IncludeWindowsTests -OutDir $OutDir
$r | ConvertTo-Json -Depth 10
switch ($r.status) { 'PASS' { exit 0 } 'INCOMPLETE' { exit 2 } default { exit 1 } }
