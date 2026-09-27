# IntuneRem helper library - canonical source.
#
# Generators copy the functions a script needs VERBATIM into the script (Intune
# scripts must be self-contained). Never edit a copied helper inside a package;
# fix it here and regenerate.
#
# Target: Windows PowerShell 5.1, SYSTEM, 64-bit. ASCII only.
# Sources for every external fact: references/sources.md.

# ---------------------------------------------------------------------------
# Logging (HR-10). Log folder and prefix per ADR-012 (D3).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Status output and exit (HR-02, HR-03). The ONLY place a status line is written.
# Write-Host matches Microsoft's Remediations samples; it is not captured by
# assignment or pipeline, so the status line cannot be swallowed.
# Under Pester this function is mocked to throw "ExitCalled:<code>".
# ---------------------------------------------------------------------------
function Exit-WithCode {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Z][A-Z_]+$')][string]$Token,
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

# ---------------------------------------------------------------------------
# Bounded process execution (HR-05, HR-14).
# ArgumentList elements are joined with spaces by Start-Process; quote any
# element that contains spaces before passing it.
# ---------------------------------------------------------------------------
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
            Write-Log -Level 'WARN' -Message ('Timeout after {0}s: {1}. Killing process tree.' -f $TimeoutSeconds, $FilePath)
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

# ---------------------------------------------------------------------------
# Versions (HR-12). Always compare [version] objects normalised to 4 parts:
# [version]'1.2' has Build = -1 and compares LOWER than [version]'1.2.0'.
# Returns $null when no version can be parsed (caller reports NOT_DETERMINED).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Install discovery (HR-09, ADR-012 D2).
# ---------------------------------------------------------------------------
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
    return , $found.ToArray()
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
    return , $hits.ToArray()
}

# ---------------------------------------------------------------------------
# winget (Pattern A, HR-15). Running winget.exe as SYSTEM is NOT supported by
# Microsoft (ADR-016); the owner accepted this risk. Every failure to locate or
# run winget maps to NOT_DETERMINED (detection) or FAILED (remediation).
# ---------------------------------------------------------------------------
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
    Write-Log -Message ('winget {0}' -f ($wgArgs -join ' '))
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
        Write-Log -Level 'WARN' -Message ('winget show failed: exit={0} timedOut={1}' -f $r.ExitCode, $r.TimedOut)
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

# winget process exit codes used by templates (source: microsoft/winget-cli returnCodes.md).
$WINGET_UPDATE_NOT_APPLICABLE = -1978335189   # 0x8A15002B No applicable update found
$WINGET_NO_APPLICATIONS_FOUND = -1978335212   # 0x8A150014 No packages found
$WINGET_REBOOT_TO_FINISH      = -1978334967   # 0x8A150109 Restart your PC to finish installation

# ---------------------------------------------------------------------------
# Secure staging (HR-07). Root and leaf are restricted to SYSTEM and
# BUILTIN\Administrators, inheritance disabled, verified before use.
# Mitigation, not elimination, of path attacks: see references/failure-modes.md.
# ---------------------------------------------------------------------------
function Test-TrustedAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return 'reparse point' }
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    $owner = (New-Object System.Security.Principal.NTAccount($acl.Owner)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    if ($trusted -notcontains $owner) { return ('untrusted owner ' + $owner) }
    if (-not $acl.AreAccessRulesProtected) { return 'inheritance enabled' }
    foreach ($r in $acl.Access) {
        $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $sid) { return ('unexpected ACE ' + $sid) }
    }
    return ''
}

function Set-TrustedAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($s)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inh, $prop, 'Allow')))
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-SecureStagingDir {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,48}$')][string]$PackageId)
    $parent = Join-Path $env:ProgramData 'IntuneRemediation'
    $root = Join-Path $parent 'Staging'
    foreach ($d in @($parent, $root)) {
        if (-not (Test-Path -LiteralPath $d)) {
            $null = New-Item -ItemType Directory -Path $d -Force
            Set-TrustedAcl -Path $d
        }
        $why = Test-TrustedAcl -Path $d
        if ($why) { throw ('staging root untrusted ({0}): {1}' -f $why, $d) }
    }
    $leaf = Join-Path $root ('{0}_{1}' -f $PackageId, (Get-Date).ToString('yyyyMMddHHmmssfff'))
    if (Test-Path -LiteralPath $leaf) { throw ('staging dir already exists: ' + $leaf) }
    $null = New-Item -ItemType Directory -Path $leaf
    Set-TrustedAcl -Path $leaf
    $why = Test-TrustedAcl -Path $leaf
    if ($why) { throw ('staging dir untrusted ({0}): {1}' -f $why, $leaf) }
    Write-Log -Message ('Staging dir ready: ' + $leaf)
    return $leaf
}

function Remove-SecureStagingDir {
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return }
    $root = Join-Path $env:ProgramData 'IntuneRemediation\Staging'
    if (-not $Path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log -Level 'ERROR' -Message ('Refusing to delete outside staging root: ' + $Path)
        return
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) { Write-Log -Level 'WARN' -Message ('Staging dir not fully removed: ' + $Path) }
    }
}

# ---------------------------------------------------------------------------
# Downloads and installer trust (HR-08).
# ---------------------------------------------------------------------------
function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][ValidateRange(1, 540)][int]$TimeoutSeconds
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $oldPp = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    } finally { $ProgressPreference = $oldPp }
}

function Get-DnField {
    # Extracts one RDN value (e.g. CN, O) from a distinguished name, honouring quotes.
    param([string]$Dn, [string]$Field)
    $m = [regex]::Match($Dn, '(?:^|,\s*)' + [regex]::Escape($Field) + '=("(?:[^"]|"")*"|[^,]*)')
    if (-not $m.Success) { return '' }
    $v = $m.Groups[1].Value
    if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2).Replace('""', '"') }
    return $v.Trim()
}

function Test-InstallerTrust {
    # Call IMMEDIATELY before executing the installer. Returns an object; the caller
    # emits FAILED (exit 1) and does not install when Trusted is $false.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSignerCN,
        [Parameter(Mandatory = $true)][string]$ExpectedSignerO,
        [string]$ExpectedSha256 = ''
    )
    $r = New-Object PSObject -Property @{ Trusted = $false; Reason = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $r.Reason = 'installer missing'; return $r }
    if ($ExpectedSha256) {
        $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($h -ne $ExpectedSha256.ToUpperInvariant()) { $r.Reason = 'SHA256 mismatch'; return $r }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$sig.Status -ne 'Valid') { $r.Reason = 'signature status ' + [string]$sig.Status; return $r }
    $subj = $sig.SignerCertificate.Subject
    $cn = Get-DnField -Dn $subj -Field 'CN'
    $o = Get-DnField -Dn $subj -Field 'O'
    if ($cn -ne $ExpectedSignerCN -or $o -ne $ExpectedSignerO) {
        $r.Reason = ('signer mismatch CN="{0}" O="{1}"' -f $cn, $o)
        return $r
    }
    $r.Trusted = $true
    return $r
}

function Test-ProcessRunning {
    param([Parameter(Mandatory = $true)][string[]]$ProcessName)
    return [bool](Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Desired state (config-change, vuln mitigations, general). Registry and Service
# kinds only in v1; other kinds need a contract and reference change.
# ---------------------------------------------------------------------------
function Test-DesiredStateEntry {
    param([Parameter(Mandatory = $true)][hashtable]$Entry)
    switch ($Entry.Kind) {
        'Registry' {
            $cur = Get-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
            if ($null -eq $cur) { return $false }
            return ([string]$cur.($Entry.Name) -eq [string]$Entry.Value)
        }
        'Service' {
            $svc = Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue
            if ($null -eq $svc) { return [bool]$Entry.AbsentIsCompliant }
            $start = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Entry.Name) -Name Start -ErrorAction SilentlyContinue).Start
            $map = @{ 'Boot' = 0; 'System' = 1; 'Automatic' = 2; 'Manual' = 3; 'Disabled' = 4 }
            return ($start -eq $map[$Entry.StartType])
        }
        default { throw ('unsupported desired-state kind: ' + $Entry.Kind) }
    }
}

function Set-DesiredStateEntry {
    # Logs the prior value first (rollback data), then applies.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)
    switch ($Entry.Kind) {
        'Registry' {
            $prior = Get-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
            $pv = '<absent>'
            if ($null -ne $prior) { $pv = [string]$prior.($Entry.Name) }
            Write-Log -Message ('ROLLBACK Registry {0}\{1} prior={2}' -f $Entry.Path, $Entry.Name, $pv)
            if (-not (Test-Path -LiteralPath $Entry.Path)) { $null = New-Item -Path $Entry.Path -Force }
            $null = New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -PropertyType $Entry.Type -Value $Entry.Value -Force
        }
        'Service' {
            $svc = Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue
            if ($null -eq $svc) { return }
            $prior = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Entry.Name) -Name Start -ErrorAction SilentlyContinue).Start
            Write-Log -Message ('ROLLBACK Service {0} priorStart={1}' -f $Entry.Name, $prior)
            Set-Service -Name $Entry.Name -StartupType $Entry.StartType
            if ($Entry.StartType -eq 'Disabled' -and $svc.Status -eq 'Running' -and $Entry.StopIfRunning) {
                Stop-Service -Name $Entry.Name -Force -ErrorAction Stop
            }
        }
        default { throw ('unsupported desired-state kind: ' + $Entry.Kind) }
    }
}
