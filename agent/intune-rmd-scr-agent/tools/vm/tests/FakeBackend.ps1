<#
In-process fake of a lab VM for testing tools/vm/Gate4.psm1 without Azure or Windows.
It speaks the same protocol as guest/GateGuest.ps1 (GATE4-RESULT / GATE4-CHUNK lines) and
simulates one app: installed version, staging leftovers, logs, firewall block, user-scope
plant. Behaviour can be broken on purpose through $Faults to prove the assertions catch it.
ASCII only.
#>
function New-FakeGateBackend {
    param(
        [string]$Target = '2.0.0.0',
        [string]$Outdated = '1.0.0.0',
        [string]$PackageId = 'upd-example',
        [ValidateSet('A', 'B1', 'cfg')][string]$Kind = 'A',
        [hashtable]$Faults = @{},
        [bool]$CanRevert = $true
    )
    $state = @{ calls = New-Object System.Collections.ArrayList; last = ''; vm = $null }
    $newVm = { @{ version = ''; logs = @(); staging = @(); blocked = $false; userPlanted = $false; reg = '0'; uploads = @{} } }
    $state.vm = & $newVm

    $emit = {
        param([hashtable]$Obj)
        $json = $Obj | ConvertTo-Json -Depth 6 -Compress
        $state.last = $json
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        $first = if ($b64.Length -gt 2800) { $b64.Substring(0, 2800) } else { $b64 }
        "[stdout]`nGATE4-RESULT $($b64.Length) $first`n[stderr]`n"
    }.GetNewClosure()

    $run = {
        param([string]$Role)
        $vm = $state.vm
        $sid = if ($Faults.notSystem) { 'S-1-5-21-1-2-3-500' } else { 'S-1-5-18' }
        $dur = if ($Faults.slow) { 600.0 } else { 3.2 }
        $line = $null; $code = 0
        if ($Role -eq 'detect') {
            $vm.logs += "IntuneRem_${PackageId}_detect_x.log"
            if ($Kind -eq 'cfg') {
                if ($vm.reg -eq '0') { $line = 'COMPLIANT | x compliant' } else { $line = 'DRIFTED | x drifted: 1 setting(s): TelemetryLevel'; $code = 1 }
            } elseif ($vm.userPlanted -and -not $vm.version) { $line = 'SKIPPED_USER_SCOPE | x found in user scope only. Skipped' }
            elseif (-not $vm.version) { $line = 'NOT_INSTALLED | x not found' }
            elseif ($vm.blocked -and $Kind -eq 'A') { $line = 'NOT_DETERMINED | x state not determined: catalog version unavailable' }
            elseif ([version]$vm.version -ge [version]$Target) { $line = "UP_TO_DATE | x $($vm.version) is up to date" }
            else { $line = "OUTDATED | x $($vm.version) is outdated. Target $Target"; $code = 1 }
        } else {
            $vm.logs += "IntuneRem_${PackageId}_remediate_x.log"
            if ($Kind -eq 'cfg') { $vm.reg = '0'; $line = 'REMEDIATED | x remediated: 1 setting(s) corrected' }
            elseif ($Role -eq 'remediate-tampered') { $line = 'FAILED | x update to 2.0 failed: signer mismatch'; $code = 1 }
            elseif ($vm.blocked) { $line = 'FAILED | x update to 2.0 failed: network'; $code = 1 }
            else {
                if (-not $Faults.noVersionChange) { $vm.version = $Target }
                if ($Faults.leaveStaging) { $vm.staging += "${PackageId}_20261002" }
                $line = "REMEDIATED | x updated to $Target"
            }
        }
        $stdout = $line
        if ($Faults.extraOutput) { $stdout = "debug noise`r`n" + $line }
        return @{ exitCode = $code; timedOut = $false; durationSec = $dur; stdout = $stdout; stderr = ''; identitySid = $sid; is64Process = $true; psVersion = '5.1.26100.1' }
    }.GetNewClosure()

    $guest = {
        param([string]$Action, [hashtable]$Params)
        $null = $state.calls.Add($Action)
        $vm = $state.vm
        $spec = $null
        if ($Params.SpecB64) { $spec = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Params.SpecB64)) | ConvertFrom-Json }
        switch ($Action) {
            'Info' { return & $emit @{ action = 'Info'; ok = $true; identitySid = 'S-1-5-18'; is64Process = $true; psVersion = '5.1.26100.1'; osVersion = '10.0.26100.0'; edition = 'Enterprise'; displayVersion = '24H2'; uiCulture = 'en-US'; wingetPath = 'C:\x\winget.exe'; pester5 = $true; padding = ('p' * 5000) } }
            'PutChunk' { $k = $Params.Name; if ($Params.Append -ne 'true') { $vm.uploads[$k] = '' }; $vm.uploads[$k] += $Params.Data; return & $emit @{ action = 'PutChunk'; ok = $true } }
            'Expand' {
                $zip = [Convert]::FromBase64String($vm.uploads[$Params.Name])
                $ms = New-Object System.IO.MemoryStream(, $zip)
                $za = New-Object System.IO.Compression.ZipArchive($ms)
                $names = @($za.Entries | ForEach-Object { $_.FullName })
                $state.payload = @{}
                foreach ($e in $za.Entries) { $sr = New-Object System.IO.StreamReader($e.Open()); $state.payload[$e.FullName] = $sr.ReadToEnd(); $sr.Close() }
                return & $emit @{ action = 'Expand'; ok = $true; files = $names }
            }
            'InstallOutdated' { $vm.version = $Outdated; return & $emit @{ action = 'InstallOutdated'; ok = $true; exitCode = 0 } }
            'BlockHosts' { $vm.blocked = $true; return & $emit @{ action = 'BlockHosts'; ok = $true } }
            'Registry' { $vm.reg = [string]$spec.value; return & $emit @{ action = 'Registry'; ok = $true } }
            'PlantUserScope' {
                if ($Faults.noProfile) { return & $emit @{ action = 'PlantUserScope'; ok = $false; error = 'NOT_RUN: no user profile on the VM' } }
                $vm.userPlanted = $true; return & $emit @{ action = 'PlantUserScope'; ok = $true }
            }
            'Run' { return & $emit @{ action = 'Run'; ok = $true; run = (& $run $Params.Role) } }
            'Collect' { return & $emit @{ action = 'Collect'; ok = $true; fileVersion = $vm.version; logs = $vm.logs; stagingLeft = $vm.staging; registryValue = $vm.reg } }
            'Pester' {
                if ($spec.matrix) { $state.gate2Matrix = $spec.matrix; return & $emit @{ action = 'Pester'; ok = $true; passed = 3; failed = [int][bool]$Faults.gate2Fails; skipped = 0; failures = @() } }
                return & $emit @{ action = 'Pester'; ok = $true; passed = 7; failed = 0; skipped = 0; failures = @() }
            }
            'Fetch' {
                $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($state.last))
                $len = [math]::Min([int]$Params.Length, [math]::Max(0, $b64.Length - [int]$Params.Offset))
                return "GATE4-CHUNK $($b64.Length) $($b64.Substring([int]$Params.Offset, $len))"
            }
        }
    }.GetNewClosure()

    $reset = {
        $null = $state.calls.Add('Reset')
        if ($Faults.resetFails) { return @{ ok = $false; seconds = 1; detail = 'snapshot missing' } }
        $state.vm = & $newVm
        return @{ ok = $true; seconds = 1; detail = 'fake revert' }
    }.GetNewClosure()

    return @{ Name = 'fake'; CanRevert = $CanRevert; Reset = $reset; Guest = $guest; State = $state }
}
