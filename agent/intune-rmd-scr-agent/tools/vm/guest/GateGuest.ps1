<#
Gate 4 guest agent. Runs on the lab VM as SYSTEM: through Azure Run Command
(RunPowerShellScript runs as System on Windows; MicrosoftDocs/azure-compute-docs
articles/virtual-machines/windows/run-command.md) or locally from an elevated shell.

Every action writes its JSON result to <work>\last.json and prints one line:
  GATE4-RESULT <length> <base64 of the first chunk>
The host fetches the rest with -Action Fetch, because Run Command returns only the last
4,096 bytes of output (same doc).

Actions:
  Info                         identity, bitness, PS and OS version, winget presence
  PutChunk  -Name -Data -Append    append base64 data to <work>\upload\<Name>.b64
  Expand    -Name              decode upload\<Name>.b64 (a zip) into <work>\pkg
  InstallOutdated -SpecB64     install the deliberately outdated version (winget or url)
  Registry  -SpecB64           set or delete one HKLM value (config-change setup)
  PlantUserScope -SpecB64      copy a versioned PE into an existing user profile path
  BlockHosts -SpecB64          outbound firewall block + hosts-file entries for hosts
  Run  -Role -Script [-TimeoutSeconds]  run a script as SYSTEM via a one-shot scheduled task
  Collect -SpecB64             file version, IntuneRem logs, leftover staging dirs
  Pester -SpecB64              run Pester 5: test files (paths) or a Gate 2 matrix's WindowsOnly scenarios (matrix)
  Fetch -Path -Offset -Length  return a base64 chunk of a work file

Lab VM only. Windows PowerShell 5.1 compatible. ASCII only.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('Info', 'PutChunk', 'Expand', 'InstallOutdated', 'Registry', 'PlantUserScope', 'BlockHosts', 'Run', 'Collect', 'Pester', 'Fetch')][string]$Action,
    [string]$Name = '',
    [string]$Data = '',
    [string]$Append = 'false',
    [string]$SpecB64 = '',
    [string]$Role = '',
    [string]$Script = '',
    [int]$TimeoutSeconds = 600,
    [string]$Path = '',
    [int]$Offset = 0,
    [int]$Length = 2800
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Work = Join-Path $env:ProgramData 'IntuneRemGate4'
$Result = [ordered]@{ action = $Action; ok = $true; error = '' }

function Initialize-Work {
    foreach ($d in @($Work, (Join-Path $Work 'upload'), (Join-Path $Work 'pkg'), (Join-Path $Work 'runs'))) {
        if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    }
}
function Get-Spec {
    if (-not $SpecB64) { return $null }
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SpecB64)) | ConvertFrom-Json)
}
function Get-WingetExe {
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $best = $null
    $bestVer = $null
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Filter ('Microsoft.DesktopAppInstaller_*_{0}__8wekyb3d8bbwe' -f $arch) -ErrorAction SilentlyContinue) {
        try { $v = [version]($d.Name.Split('_')[1]) } catch { continue }
        if (($null -eq $bestVer) -or ($v -gt $bestVer)) { $bestVer = $v; $best = $d.FullName }
    }
    if ($best -and (Test-Path -LiteralPath (Join-Path $best 'winget.exe'))) { return (Join-Path $best 'winget.exe') }
    return $null
}
function Invoke-Bounded([string]$File, [string[]]$Arguments, [int]$Seconds) {
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($Seconds * 1000)) {
        $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $k = Start-Process -FilePath $tk -ArgumentList @('/PID', $p.Id, '/T', '/F') -NoNewWindow -PassThru
        $null = $k.WaitForExit(30000)
        return @{ exitCode = $null; timedOut = $true }
    }
    return @{ exitCode = $p.ExitCode; timedOut = $false }
}
function Get-FileVersionString([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($File)
    return ('{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
}
function Write-Result {
    $json = $Result | ConvertTo-Json -Depth 6 -Compress
    $last = Join-Path $Work 'last.json'
    Set-Content -LiteralPath $last -Value $json -Encoding ASCII
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    $first = $b64
    if ($first.Length -gt 2800) { $first = $first.Substring(0, 2800) }
    Write-Output ('GATE4-RESULT {0} {1}' -f $b64.Length, $first)
}

try {
    Initialize-Work
    switch ($Action) {
        'Info' {
            $Result.identitySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $Result.is64Process = [Environment]::Is64BitProcess
            $Result.psVersion = $PSVersionTable.PSVersion.ToString()
            $Result.osVersion = [Environment]::OSVersion.Version.ToString()
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
            $Result.edition = [string]$cv.EditionID
            $Result.displayVersion = [string]$cv.DisplayVersion
            $Result.uiCulture = (Get-UICulture).Name
            $Result.wingetPath = [string](Get-WingetExe)
            $Result.pester5 = [bool](Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -eq 5 })
        }
        'PutChunk' {
            if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw 'bad name' }
            $f = Join-Path (Join-Path $Work 'upload') ($Name + '.b64')
            if ($Append -ne 'true' -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force }
            Add-Content -LiteralPath $f -Value $Data -NoNewline -Encoding ASCII
            $Result.size = (Get-Item -LiteralPath $f).Length
        }
        'Expand' {
            if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw 'bad name' }
            $b64 = Get-Content -LiteralPath (Join-Path (Join-Path $Work 'upload') ($Name + '.b64')) -Raw
            $zip = Join-Path $Work ($Name + '.zip')
            [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
            $pkg = Join-Path $Work 'pkg'
            Remove-Item -LiteralPath $pkg -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -LiteralPath $zip -DestinationPath $pkg -Force
            $Result.files = @(Get-ChildItem -LiteralPath $pkg -Recurse -File | ForEach-Object { $_.FullName.Substring($pkg.Length + 1) })
        }
        'InstallOutdated' {
            $s = Get-Spec
            if ($s.method -eq 'winget') {
                $wg = Get-WingetExe
                if (-not $wg) { throw 'winget not found on the VM' }
                $r = Invoke-Bounded $wg @('install', '--id', $s.id, '--exact', '--version', $s.version, '--source', 'winget', '--scope', 'machine', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') 900
            } elseif ($s.method -eq 'url') {
                if ($s.url -notmatch '^https://') { throw 'url must be https' }
                if ($s.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'sha256 required for url installs' }
                $dl = Join-Path $Work ('outdated' + [System.IO.Path]::GetExtension($s.url))
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $s.url -OutFile $dl -UseBasicParsing -TimeoutSec 600
                if ((Get-FileHash -LiteralPath $dl -Algorithm SHA256).Hash -ne $s.sha256.ToUpperInvariant()) { throw 'outdated installer hash mismatch' }
                if ($dl -like '*.msi') {
                    $r = Invoke-Bounded (Join-Path $env:SystemRoot 'System32\msiexec.exe') (@('/i', ('"{0}"' -f $dl), '/qn', '/norestart') + @($s.args)) 900
                } else {
                    $r = Invoke-Bounded $dl @($s.args) 900
                }
            } else { throw ('unknown install method: ' + $s.method) }
            $Result.exitCode = $r.exitCode
            $Result.timedOut = $r.timedOut
        }
        'Registry' {
            $s = Get-Spec
            if ($s.path -notlike 'HKLM:\*') { throw 'only HKLM is allowed' }
            if ($s.delete) {
                Remove-ItemProperty -LiteralPath $s.path -Name $s.name -ErrorAction SilentlyContinue
            } else {
                if (-not (Test-Path -LiteralPath $s.path)) { $null = New-Item -Path $s.path -Force }
                $null = New-ItemProperty -LiteralPath $s.path -Name $s.name -PropertyType $s.type -Value $s.value -Force
            }
        }
        'PlantUserScope' {
            $s = Get-Spec
            $userProfile = $null
            foreach ($pk in Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList') {
                if ($pk.PSChildName -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
                $img = [string]$pk.GetValue('ProfileImagePath')
                if ($img -and (Test-Path -LiteralPath $img)) { $userProfile = $img; break }
            }
            if (-not $userProfile) { throw 'NOT_RUN: no user profile on the VM; sign in once with a user account before the baseline snapshot' }
            $dest = Join-Path $userProfile $s.relPath
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
            Copy-Item -LiteralPath $s.from -Destination $dest -Force
            $Result.planted = $dest.Replace($userProfile, '<profile>')
        }
        'BlockHosts' {
            $s = Get-Spec
            $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            $ips = New-Object System.Collections.ArrayList
            foreach ($h in @($s.hosts)) {
                if ($h -notmatch '^[A-Za-z0-9.-]+$') { throw ('bad host ' + $h) }
                foreach ($rec in @(Resolve-DnsName -Name $h -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress })) { $null = $ips.Add($rec.IPAddress) }
                Add-Content -LiteralPath $hostsFile -Value ('0.0.0.0 {0} # IntuneRemGate4' -f $h) -Encoding ASCII
            }
            if ($ips.Count -gt 0) {
                $null = New-NetFirewallRule -DisplayName 'IntuneRemGate4 block' -Group 'IntuneRemGate4' -Direction Outbound -Action Block -RemoteAddress @($ips | Sort-Object -Unique)
            }
            Clear-DnsClientCache
            $Result.blockedAddresses = $ips.Count
        }
        'Run' {
            if ($Role -notin @('detect', 'remediate', 'remediate-tampered')) { throw 'bad role' }
            $scriptPath = Join-Path (Join-Path $Work 'pkg') $Script
            if (-not (Test-Path -LiteralPath $scriptPath)) { throw ('script not staged: ' + $Script) }
            $runner = Join-Path (Join-Path $Work 'pkg') 'Start-ScriptRun.ps1'
            $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff')
            $resPath = Join-Path (Join-Path $Work 'runs') ('{0}-{1}.json' -f $Role, $stamp)
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Script "{1}" -ResultPath "{2}" -TimeoutSeconds {3}' -f $runner, $scriptPath, $resPath, $TimeoutSeconds
            $task = 'IntuneRemGate4-' + $stamp
            $act = New-ScheduledTaskAction -Execute $psExe -Argument $arg
            $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $null = Register-ScheduledTask -TaskName $task -Action $act -Principal $prin -Force
            try {
                Start-ScheduledTask -TaskName $task
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 90)
                while (-not (Test-Path -LiteralPath $resPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            } finally {
                Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath $resPath)) { throw 'runner produced no result before the deadline' }
            $Result.run = Get-Content -LiteralPath $resPath -Raw | ConvertFrom-Json
        }
        'Collect' {
            $s = Get-Spec
            $Result.fileVersion = ''
            if ($s.versionPath) { $Result.fileVersion = Get-FileVersionString $s.versionPath }
            $logDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
            $Result.logs = @(Get-ChildItem -LiteralPath $logDir -Filter ('IntuneRem_{0}_*.log' -f $s.packageId) -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            $stg = Join-Path $env:ProgramData 'IntuneRemediation\Staging'
            $Result.stagingLeft = @(Get-ChildItem -LiteralPath $stg -Directory -Filter ('{0}_*' -f $s.packageId) -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            if ($s.registry) {
                $v = Get-ItemProperty -LiteralPath $s.registry.path -Name $s.registry.name -ErrorAction SilentlyContinue
                $Result.registryValue = $null
                if ($null -ne $v) { $Result.registryValue = [string]$v.($s.registry.name) }
            }
        }
        'Pester' {
            $s = Get-Spec
            $p5 = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
            if (-not $p5) { throw 'NOT_RUN: Pester 5 is not installed on the VM (see tools/vm/guest/Initialize-GateVm.ps1)' }
            Import-Module $p5.Path -Force
            $cfg = New-PesterConfiguration
            if ($s.matrix) {
                # Gate 2 WindowsOnly scenarios of the package, run here on real Windows.
                $pkgDir = Join-Path $Work 'pkg'
                . (Join-Path $pkgDir 'gate2/Mocks.ps1')
                $all = @(& (Join-Path $pkgDir ('gate2/' + $s.matrix)))
                $win = @($all | Where-Object { $_.WindowsOnly })
                if ($win.Count -eq 0) { throw 'NOT_RUN: the matrix has no WindowsOnly scenarios' }
                $Result.scenarioCount = $win.Count
                $cfg.Run.Container = New-PesterContainer -Path (Join-Path $pkgDir 'gate2/Package.Tests.ps1') -Data @{ PackagePath = $pkgDir; Scenarios = $win }
            } else {
                $cfg.Run.Path = @($s.paths | ForEach-Object { Join-Path (Join-Path $Work 'pkg') $_ })
            }
            $cfg.Run.PassThru = $true
            $cfg.Output.Verbosity = 'None'
            $r = Invoke-Pester -Configuration $cfg
            $Result.passed = $r.PassedCount
            $Result.failed = $r.FailedCount
            $Result.skipped = $r.SkippedCount
            $Result.failures = @($r.Failed | ForEach-Object { @{ name = $_.ExpandedPath; message = [string]($_.ErrorRecord | Select-Object -First 1) } })
        }
        'Fetch' {
            $full = [System.IO.Path]::GetFullPath((Join-Path $Work $Path))
            if (-not $full.StartsWith($Work + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'path outside work dir' }
            $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full))
            $len = [math]::Min($Length, [math]::Max(0, $b64.Length - $Offset))
            Write-Output ('GATE4-CHUNK {0} {1}' -f $b64.Length, $b64.Substring($Offset, $len))
            return
        }
    }
} catch {
    $Result.ok = $false
    $Result.error = $_.Exception.Message
}
Write-Result
