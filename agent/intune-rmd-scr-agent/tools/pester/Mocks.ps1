<#
Gate 2 shared mock builders. Dot-sourced by Package.Tests.ps1 and the helper tests.
Defined in global scope because scenario mock scriptblocks are created in the matrix
files and run later inside Pester, where the matrix file's own scope no longer exists.
Default mocks (Exit-WithCode -> throw "ExitCalled:<code>", logging, Write-Host) are set
by Package.Tests.ps1 itself. ASCII only.
#>

# Result of Get-InstalledAppVersion.
function global:New-AppState([string]$Status, [string]$Version) {
    $v = $null
    if ($Version) { $v = [version]$Version }
    return New-Object PSObject -Property @{ Status = $Status; Version = $v; UserCount = 0 }
}

# Result of Invoke-ProcessWithTimeout / Invoke-Winget.
function global:New-ProcResult($ExitCode = 0, [bool]$TimedOut = $false, [string]$StdOut = '', [string]$StdErr = '') {
    return New-Object PSObject -Property @{ ExitCode = $ExitCode; TimedOut = $TimedOut; StdOut = $StdOut; StdErr = $StdErr }
}

# Result of Test-InstallerTrust.
function global:New-TrustResult([bool]$Trusted, [string]$Reason = '') {
    return New-Object PSObject -Property @{ Trusted = $Trusted; Reason = $Reason }
}

# Row of Get-MachineInstall.
function global:New-MachineInstall([string]$DisplayName, [string]$DisplayVersion) {
    return New-Object PSObject -Property @{ Scope = 'Machine'; View = 'Registry64'; KeyName = 'k'; DisplayName = $DisplayName; DisplayVersion = $DisplayVersion; InstallLocation = ''; Publisher = '' }
}

# Row of Get-UserScopeInstall.
function global:New-UserInstall([string]$Source = 'Path') {
    return New-Object PSObject -Property @{ Scope = 'User'; Source = $Source; Sid = 'S-1-12-1-1-2-3-4'; Path = 'x'; DisplayVersion = '' }
}

# Call counter for stateful mocks (first call returns A, later calls return B).
function global:Step-G2Counter([string]$Name) {
    if (-not $global:G2) { $global:G2 = @{} }
    $global:G2[$Name] = 1 + [int]$global:G2[$Name]
    return $global:G2[$Name]
}
