<#
One-time preparation of the Gate 4 VM, run as SYSTEM (Run Command) or from an elevated
shell BEFORE taking the 'baseline' snapshot. Lab VM only. ASCII only.

It:
  1. installs the NuGet provider and Pester 5 for all users (for the Windows-only tests);
  2. reports whether winget (App Installer) is present for SYSTEM;
  3. reports edition, version, UI language and whether a user profile exists (needed by
     the user-scope-only scenario).
It does not enrol the VM in Intune: the Gate 4 VM must stay unenrolled (ADR-017).
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$report = [ordered]@{}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers
    Install-Module -Name Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -Force -SkipPublisherCheck -Scope AllUsers -AllowClobber
    $report.pester = [string](Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1).Version
} catch { $report.pester = 'FAILED: ' + $_.Exception.Message }

$wg = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Directory -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
$report.winget = if ($wg -and (Test-Path -LiteralPath (Join-Path $wg.FullName 'winget.exe'))) { $wg.Name } else { 'NOT FOUND (sign in once and update App Installer, then re-run)' }

$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$report.edition = [string]$cv.EditionID
$report.displayVersion = [string]$cv.DisplayVersion
$report.build = [string]$cv.CurrentBuild
$report.uiCulture = (Get-UICulture).Name
$report.userProfiles = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
    Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' }).Count
$report | ConvertTo-Json
