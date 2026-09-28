<#
Package:   upd-exampleb1
Type:      app-update
Role:      detect
Contract:  1.0.0
Generated: fixture-composer
Summary:   Test fixture: Pattern B1 vendor MSI with secure staging and trust check
#>

# ===== Constants (HR-04: every timeout is declared here; sum <= 540 s) =====
$PACKAGE_ID = 'upd-exampleb1'
$SUBJECT    = 'Example Tool'
$DISPLAY_NAME_LIKE  = 'Example Tool*'
$MAIN_EXE_PATHS     = @('C:\Program Files\Example Tool\tool.exe')
$USER_EXE_RELPATHS  = @('AppData\Local\Example Tool\tool.exe')
$VERSION_SOURCE     = 'FileVersion'
$TARGET_VERSION     = '5.2.0.0'
$DOWNLOAD_URL       = 'https://downloads.example.invalid/tool/5.2.0/tool-x64.msi'
$EXPECTED_SIGNER_CN = 'Example Vendor Ltd'
$EXPECTED_SIGNER_O  = 'Example Vendor Ltd'
$EXPECTED_SHA256    = ''
$TIMEOUT_DOWNLOAD   = 120
$TIMEOUT_INSTALL    = 300

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

function Write-Log {
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
    Write-Log -Message ('STATUS exit={0} {1}' -f $Code, $line)
    Write-Host $line
    exit $Code
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

function Get-MachineInstalls {
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
    # @(Get-MachineInstalls ...) a one-element array even when nothing was found.
    return $found.ToArray()
}

function Get-UserScopeInstalls {
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
    $machine = @(Get-MachineInstalls -DisplayNamePattern $DisplayNamePattern)
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
        $user = @(Get-UserScopeInstalls -DisplayNamePattern $DisplayNamePattern -RelativeExePaths $UserExeRelPaths)
        $r.UserCount = $user.Count
        if ($user.Count -gt 0) { $r.Status = 'UserOnly' } else { $r.Status = 'Absent' }
        return $r
    }
    if ($null -eq $installed) { $r.Status = 'Unreadable' } else { $r.Status = 'Machine' }
    return $r
}

# ===== Main =====
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'detect'
    Write-Log -Message ('Start detect. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

    $app = Get-InstalledAppVersion -DisplayNamePattern $DISPLAY_NAME_LIKE -MainExePaths $MAIN_EXE_PATHS -UserExeRelPaths $USER_EXE_RELPATHS -VersionSource $VERSION_SOURCE
    if ($app.Status -eq 'UserOnly') {
        Exit-WithCode -Token 'SKIPPED_USER_SCOPE' -Message ('{0} found in user scope only. Skipped' -f $SUBJECT) -Code 0
    }
    if ($app.Status -eq 'Absent') {
        Exit-WithCode -Token 'NOT_INSTALLED' -Message ('{0} not found' -f $SUBJECT) -Code 0
    }
    $target = ConvertTo-NormalizedVersion $TARGET_VERSION
    if ($app.Status -eq 'Unreadable' -or $null -eq $target) {
        Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: version unreadable' -f $SUBJECT) -Code 0
    }
    if ($app.Version -ge $target) {
        Exit-WithCode -Token 'UP_TO_DATE' -Message ('{0} {1} is up to date' -f $SUBJECT, $app.Version) -Code 0
    }
    Exit-WithCode -Token 'OUTDATED' -Message ('{0} {1} is outdated. Target {2}' -f $SUBJECT, $app.Version, $target) -Code 1
}
catch {
    if ($_.Exception.Message -like 'ExitCalled:*') { throw }
    $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace '[^\x20-\x7E]', '?')
    Write-Log -Level 'ERROR' -Message ('Unhandled: ' + $reason)
    Write-Host ('ERROR | {0} script error: {1}' -f $SUBJECT, $reason)
    exit 0
}
