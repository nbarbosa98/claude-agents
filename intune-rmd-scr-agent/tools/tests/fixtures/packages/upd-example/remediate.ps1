<#
Package:   upd-example
Type:      app-update
Role:      remediate
Contract:  1.0.0
Generated: fixture-composer
Summary:   Test fixture: Pattern A (winget) update of a fictional app
#>

# ===== Constants (HR-04: every timeout is declared here; sum <= 540 s) =====
$PACKAGE_ID = 'upd-example'
$SUBJECT    = 'Example App'
$DISPLAY_NAME_LIKE = 'Example App*'
$MAIN_EXE_PATHS    = @('C:\Program Files\Example App\example.exe')
$USER_EXE_RELPATHS = @('AppData\Local\Programs\Example App\example.exe')
$VERSION_SOURCE    = 'FileVersion'
$WINGET_ID         = 'Example.App'
$INCLUDE_UNKNOWN   = $false
$TIMEOUT_CATALOG   = 60
$WINGET_REBOOT_TO_FINISH = -1978334967
$TIMEOUT_UPGRADE   = 300

# ===== Helpers (copied verbatim from references/helpers.ps1) =====
function Initialize-Log {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,48}$')][string]$PackageId,
        [Parameter(Mandatory = $true)][ValidateSet('detect', 'remediate')][string]$Role,
        [int]$RetentionDays = 30
    )
    $dir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogFile = Join-Path $dir ('IntuneRem_{0}_{1}_{2}.log' -f $PackageId, $Role, $stamp)
    # Prefix-scoped pruning: this package's own logs only. A generic glob in this
    # folder would delete the Intune Management Extension's own logs.
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $dir -Filter ('IntuneRem_{0}_*.log' -f $PackageId) -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-RemediationLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Logging must never fail the run; the status line is the contract.')]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not $script:LogFile) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding ASCII -ErrorAction Stop } catch { }
}

function Exit-WithCode {
    param(
        # ValidatePattern is case-insensitive; -cmatch keeps tokens upper case.
        [Parameter(Mandatory = $true)][ValidateScript({ $_ -cmatch '^[A-Z][A-Z_]+$' })][string]$Token,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateSet(0, 1)][int]$Code
    )
    $line = '{0} | {1}' -f $Token, ($Message -replace '[\r\n\t]+', ' ')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $line.ToCharArray()) {
        if ([int]$ch -ge 32 -and [int]$ch -le 126) { $null = $sb.Append($ch) } else { $null = $sb.Append('?') }
    }
    $line = $sb.ToString()
    if ($line.Length -gt 512) { $line = $line.Substring(0, 509) + '...' }
    Write-RemediationLog -Message ('STATUS exit={0} {1}' -f $Code, $line)
    Write-Host $line
    exit $Code
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][ValidateRange(1, 540)][int]$TimeoutSeconds,
        [switch]$CaptureOutput
    )
    $result = New-Object PSObject -Property @{ ExitCode = $null; TimedOut = $false; StdOut = ''; StdErr = '' }
    $outFile = $null
    $errFile = $null
    $sp = @{ FilePath = $FilePath; PassThru = $true; NoNewWindow = $true }
    if ($ArgumentList.Count -gt 0) { $sp.ArgumentList = $ArgumentList }
    if ($CaptureOutput) {
        # Text capture files only, never executed, so $env:TEMP is acceptable (ADR-018).
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $sp.RedirectStandardOutput = $outFile
        $sp.RedirectStandardError = $errFile
    }
    try {
        $p = Start-Process @sp
        # Touch the handle so ExitCode is populated after exit (Windows PowerShell 5.1
        # behaviour with -PassThru; UNVERIFIED in official docs, confirmed in lab Phase 3).
        $null = $p.Handle
        if ($p.WaitForExit($TimeoutSeconds * 1000)) {
            $result.ExitCode = $p.ExitCode
        } else {
            $result.TimedOut = $true
            Write-RemediationLog -Level 'WARN' -Message ('Timeout after {0}s: {1}. Killing process tree.' -f $TimeoutSeconds, $FilePath)
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $k = Start-Process -FilePath $tk -ArgumentList @('/PID', $p.Id, '/T', '/F') -PassThru -NoNewWindow
            $null = $k.WaitForExit(15000)
        }
        if ($CaptureOutput) {
            $result.StdOut = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            $result.StdErr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
    } finally {
        foreach ($f in @($outFile, $errFile)) {
            if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
    return $result
}

function ConvertTo-NormalizedVersion {
    param([AllowNull()][AllowEmptyString()][string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }
    $m = [regex]::Match($VersionString, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = New-Object System.Collections.ArrayList
    foreach ($p in $m.Value.Split('.')) { $null = $parts.Add($p) }
    while ($parts.Count -lt 4) { $null = $parts.Add('0') }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Get-FileVersionSafe {
    # Trust order (HR-12): file version parts first. Built from the numeric parts,
    # never from the FileVersion string, which vendors format freely.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $v = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
        if ($v -eq '0.0.0.0') { return $null }
        return ConvertTo-NormalizedVersion $v
    } catch { return $null }
}

function Get-MachineInstall {
    # HKLM Uninstall in BOTH registry views (64-bit and WOW6432Node).
    param([Parameter(Mandatory = $true)][string]$DisplayNamePattern)
    $found = New-Object System.Collections.ArrayList
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        $uk = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $uk = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -ne $uk) {
                foreach ($name in $uk.GetSubKeyNames()) {
                    $k = $uk.OpenSubKey($name)
                    if ($null -eq $k) { continue }
                    try {
                        $dn = [string]$k.GetValue('DisplayName')
                        if ($dn -and ($dn -like $DisplayNamePattern)) {
                            $null = $found.Add((New-Object PSObject -Property @{
                                Scope           = 'Machine'
                                View            = [string]$view
                                KeyName         = $name
                                DisplayName     = $dn
                                DisplayVersion  = [string]$k.GetValue('DisplayVersion')
                                InstallLocation = [string]$k.GetValue('InstallLocation')
                                Publisher       = [string]$k.GetValue('Publisher')
                            }))
                        }
                    } finally { $k.Close() }
                }
            }
        } finally {
            if ($uk) { $uk.Close() }
            if ($base) { $base.Close() }
        }
    }
    # Emit items one by one (callers wrap the call in @()). 'return , $array' would make
    # @(Get-MachineInstall ...) a one-element array even when nothing was found.
    return $found.ToArray()
}

function Get-UserScopeInstall {
    # Profile paths come from ProfileList (not C:\Users guessing, not $env vars,
    # which point at the SYSTEM profile under SYSTEM - HR-06).
    # HKU: loaded hives only (signed-in users). NTUSER.DAT of signed-out users is
    # never loaded (ADR-012). SIDs: local/AD S-1-5-21-*, Entra ID S-1-12-1-*
    # (Entra prefix UNVERIFIED in official docs; confirmed in lab Phase 3).
    param(
        [Parameter(Mandatory = $true)][string]$DisplayNamePattern,
        [string[]]$RelativeExePaths = @()
    )
    $hits = New-Object System.Collections.ArrayList
    $sidPattern = '^S-1-(5-21|12-1)-[\d-]+$'
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($pk in Get-ChildItem -LiteralPath $pl -ErrorAction SilentlyContinue) {
        if ($pk.PSChildName -notmatch $sidPattern) { continue }
        $img = [string]$pk.GetValue('ProfileImagePath')
        if (-not $img) { continue }
        foreach ($rel in $RelativeExePaths) {
            $p = Join-Path $img $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $null = $hits.Add((New-Object PSObject -Property @{ Scope = 'User'; Source = 'Path'; Sid = $pk.PSChildName; Path = $p; DisplayVersion = '' }))
            }
        }
    }
    foreach ($sk in Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue) {
        if ($sk.PSChildName -notmatch $sidPattern) { continue }
        $up = 'Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Uninstall' -f $sk.PSChildName
        foreach ($k in Get-ChildItem -LiteralPath $up -ErrorAction SilentlyContinue) {
            $dn = [string]$k.GetValue('DisplayName')
            if ($dn -and ($dn -like $DisplayNamePattern)) {
                $null = $hits.Add((New-Object PSObject -Property @{ Scope = 'User'; Source = 'HKU'; Sid = $sk.PSChildName; Path = ''; DisplayVersion = [string]$k.GetValue('DisplayVersion') }))
            }
        }
    }
    return $hits.ToArray()
}

function Get-InstalledAppVersion {
    # The shared installed-version routine (HR-09, HR-12). Detect and remediate call the
    # same function, so they can never disagree about the installed version (FM-13).
    # Status: Machine | UserOnly | Absent | Unreadable.
    param(
        [Parameter(Mandatory = $true)][string]$DisplayNamePattern,
        [string[]]$MainExePaths = @(),
        [string[]]$UserExeRelPaths = @(),
        [Parameter(Mandatory = $true)][ValidateSet('FileVersion', 'DisplayVersion')][string]$VersionSource
    )
    $machine = @(Get-MachineInstall -DisplayNamePattern $DisplayNamePattern)
    $exeFound = $false
    $installed = $null
    foreach ($p in $MainExePaths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $exeFound = $true }
        if ($VersionSource -eq 'FileVersion') {
            $v = Get-FileVersionSafe -Path $p
            if ($v -and (($null -eq $installed) -or ($v -gt $installed))) { $installed = $v }
        }
    }
    if ($null -eq $installed) {
        foreach ($m in $machine) {
            $v = ConvertTo-NormalizedVersion $m.DisplayVersion
            if ($v -and (($null -eq $installed) -or ($v -gt $installed))) { $installed = $v }
        }
    }
    $r = New-Object PSObject -Property @{ Status = ''; Version = $installed; UserCount = 0 }
    if ($machine.Count -eq 0 -and -not $exeFound) {
        $user = @(Get-UserScopeInstall -DisplayNamePattern $DisplayNamePattern -RelativeExePaths $UserExeRelPaths)
        $r.UserCount = $user.Count
        if ($user.Count -gt 0) { $r.Status = 'UserOnly' } else { $r.Status = 'Absent' }
        return $r
    }
    if ($null -eq $installed) { $r.Status = 'Unreadable' } else { $r.Status = 'Machine' }
    return $r
}

function Get-WingetPath {
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $best = $null
    $bestVer = $null
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Filter ('Microsoft.DesktopAppInstaller_*_{0}__8wekyb3d8bbwe' -f $arch) -ErrorAction SilentlyContinue) {
        $v = ConvertTo-NormalizedVersion ($d.Name.Split('_')[1])
        if ($v -and (($null -eq $bestVer) -or ($v -gt $bestVer))) { $bestVer = $v; $best = $d.FullName }
    }
    if (-not $best) { return $null }
    $exe = Join-Path $best 'winget.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    return $null
}

function Invoke-Winget {
    # Builds every winget command line so required flags can never be forgotten.
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][ValidateSet('show-versions', 'upgrade')][string]$Operation,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]*$')][string]$PackageId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [switch]$IncludeUnknown
    )
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    if ($Operation -eq 'show-versions') {
        $wgArgs = @('show') + $common + @('--versions')
    } else {
        $wgArgs = @('upgrade') + $common + @('--scope', 'machine', '--silent', '--accept-package-agreements')
        if ($IncludeUnknown) { $wgArgs += '--include-unknown' }
    }
    Write-RemediationLog -Message ('winget {0}' -f ($wgArgs -join ' '))
    return Invoke-ProcessWithTimeout -FilePath $WingetPath -ArgumentList $wgArgs -TimeoutSeconds $TimeoutSeconds -CaptureOutput
}

function Get-WingetCatalogVersion {
    # Locale-independent: 'winget show --versions' prints localised headers, then
    # one version per line. Only lines that are a bare version are considered, so
    # header wording in any UI language is ignored (ADR-019; lab-verified in Phase 3).
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $r = Invoke-Winget -WingetPath $WingetPath -Operation 'show-versions' -PackageId $PackageId -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut -or $r.ExitCode -ne 0) {
        Write-RemediationLog -Level 'WARN' -Message ('winget show failed: exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
        return $null
    }
    $max = $null
    foreach ($ln in ($r.StdOut -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t -match '^\d+(\.\d+){1,3}$') {
            $v = ConvertTo-NormalizedVersion $t
            if ($v -and (($null -eq $max) -or ($v -gt $max))) { $max = $v }
        }
    }
    return $max
}

function Remove-SecureStagingDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Unattended SYSTEM script: no interactive caller, -WhatIf/-Confirm have no meaning.')]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return }
    $root = Join-Path $env:ProgramData 'IntuneRemediation\Staging'
    if (-not $Path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-RemediationLog -Level 'ERROR' -Message ('Refusing to delete outside staging root: ' + $Path)
        return
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) { Write-RemediationLog -Level 'WARN' -Message ('Staging dir not fully removed: ' + $Path) }
    }
}

# ===== Main =====
$stagingDir = $null
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'remediate'
    Write-RemediationLog -Message ('Start remediate. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

    # HR-19: re-check state first; exit with the compliant token if nothing to do.
    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    Write-RemediationLog -Message ('Install status {0}, version {1}' -f $app.Status, $app.Version)
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    $winget = Get-WingetPath
    if (-not $winget) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to catalog failed: winget not found' -f $SUBJECT) -Code 1
    }
    $target = Get-WingetCatalogVersion -WingetPath $winget -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_CATALOG
    if ($null -eq $target) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to catalog failed: catalog version unavailable' -f $SUBJECT) -Code 1
    }
    if ($app.Status -eq 'Machine' -and $app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade' -PackageId $WINGET_ID -TimeoutSeconds $TIMEOUT_UPGRADE -IncludeUnknown:$INCLUDE_UNKNOWN
    Write-RemediationLog -Message ('winget upgrade exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
    $after = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    if ($after.Status -eq 'Machine' -and $after.Version -ge $target) {
        Exit-WithCode -Token 'REMEDIATED' -Message ('{0} updated to {1}' -f $SUBJECT, $after.Version) -Code 0
    }
    if ($r.ExitCode -eq $WINGET_REBOOT_TO_FINISH) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    if ($r.TimedOut) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: winget timed out' -f $SUBJECT, $target) -Code 1
    }
    Exit-WithCode -Token 'FAILED' -Message ('{0} update to {1} failed: winget exit {2}, installed {3}' -f $SUBJECT, $target, $r.ExitCode, $after.Version) -Code 1
}
catch {
    if ($_.Exception.Message -like 'ExitCalled:*') { throw }
    $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace '[^\x20-\x7E]', '?')
    Write-RemediationLog -Level 'ERROR' -Message ('Unhandled: ' + $reason)
    Write-Host ('ERROR | {0} script error: {1}' -f $SUBJECT, $reason)
    exit 1
}
finally {
    Remove-SecureStagingDir -Path $stagingDir
}
