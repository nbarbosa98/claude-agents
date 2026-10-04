<#
Gate 4 backend: run the guest agent on THIS Windows machine from an elevated PowerShell
(for example inside the lab VM over RDP). It cannot revert to a snapshot, so Invoke-Gate4
reports INCOMPLETE (not deliverable). Useful to debug the harness and to run the
Windows-only tests. Refuses to run off Windows. ASCII only.
#>
function New-LocalGateBackend {
    $onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if (-not $onWindows) { throw 'the local backend runs only on Windows' }
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'the local backend needs an elevated (administrator) shell' }
    $guestScript = (Resolve-Path (Join-Path $PSScriptRoot '../guest/GateGuest.ps1')).Path
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return @{
        Name      = 'local'
        CanRevert = $false
        Reset     = { @{ ok = $false; seconds = 0; detail = 'local backend cannot revert' } }
        Guest     = {
            param([string]$Action, [hashtable]$Params)
            $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $guestScript, '-Action', $Action)
            foreach ($k in $Params.Keys) { $a += @("-$k", [string]$Params[$k]) }
            return ((& $psExe @a) | Out-String)
        }.GetNewClosure()
    }
}
