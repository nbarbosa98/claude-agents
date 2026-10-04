<#
Gate 4 guest runner. Launched by a one-shot scheduled task running as SYSTEM in 64-bit
Windows PowerShell (GateGuest.ps1 -Action Run). Starts the script under test in a fresh
64-bit powershell.exe with -ExecutionPolicy Bypass (how unsigned Remediations run, per
memdocs deploy-remediations.md), captures stdout/stderr and the exit code, enforces a hard
kill at -TimeoutSeconds, and writes a JSON result file.
Windows PowerShell 5.1 compatible. ASCII only.
#>
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$out = $ResultPath + '.stdout'
$err = $ResultPath + '.stderr'
$res = [ordered]@{
    script = $Script; exitCode = $null; timedOut = $false; durationSec = $null
    stdout = ''; stderr = ''; identitySid = ''; is64Process = [Environment]::Is64BitProcess
    psVersion = $PSVersionTable.PSVersion.ToString(); osVersion = [Environment]::OSVersion.Version.ToString(); error = ''
}
try {
    $res.identitySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Script)) `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    $null = $p.Handle
    if ($p.WaitForExit($TimeoutSeconds * 1000)) {
        $res.exitCode = $p.ExitCode
    } else {
        $res.timedOut = $true
        $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $k = Start-Process -FilePath $tk -ArgumentList @('/PID', $p.Id, '/T', '/F') -NoNewWindow -PassThru
        $null = $k.WaitForExit(30000)
    }
    $sw.Stop()
    $res.durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res.stdout = [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
    $res.stderr = [string](Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)
} catch {
    $res.error = $_.Exception.Message
}
$tmp = $ResultPath + '.tmp'
($res | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmp -Encoding ASCII
Move-Item -LiteralPath $tmp -Destination $ResultPath -Force
