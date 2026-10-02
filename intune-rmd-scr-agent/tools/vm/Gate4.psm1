<#
Gate 4 core (host side, PowerShell 7 on macOS/Linux/Windows). Backend-agnostic: a backend
is a hashtable with
  Name     [string]
  CanRevert [bool]
  Reset    { } -> @{ ok = [bool]; seconds = [double]; detail = [string] }
  Guest    { param([string]$Action, [hashtable]$Params) } -> raw text output of
           tools/vm/guest/GateGuest.ps1 (lines 'GATE4-RESULT ...' / 'GATE4-CHUNK ...')
Backends: backends/Azure.ps1, backends/Local.ps1; tests use a fake. ASCII only.
#>
Set-StrictMode -Version 3.0

$script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ChunkChars = 16000
$script:Budget = 540
$script:SystemSid = 'S-1-5-18'

# ---------------------------------------------------------------------------
# Guest protocol
# ---------------------------------------------------------------------------
function Invoke-GuestAction {
    param([Parameter(Mandatory = $true)][hashtable]$Backend, [Parameter(Mandatory = $true)][string]$Action, [hashtable]$Params = @{})
    $raw = [string](& $Backend.Guest $Action $Params)
    $m = [regex]::Match($raw, 'GATE4-RESULT (\d+) ([A-Za-z0-9+/=]*)')
    if (-not $m.Success) { throw ('guest action {0}: no GATE4-RESULT line in output: {1}' -f $Action, ($raw -replace '\s+', ' ').Substring(0, [math]::Min(300, $raw.Length))) }
    $total = [int]$m.Groups[1].Value
    $b64 = $m.Groups[2].Value
    while ($b64.Length -lt $total) {
        $c = [string](& $Backend.Guest 'Fetch' @{ Path = 'last.json'; Offset = $b64.Length; Length = 2800 })
        $cm = [regex]::Match($c, 'GATE4-CHUNK (\d+) ([A-Za-z0-9+/=]*)')
        if (-not $cm.Success -or $cm.Groups[2].Value.Length -eq 0) { throw ('guest fetch failed after {0} of {1} chars' -f $b64.Length, $total) }
        $b64 += $cm.Groups[2].Value
    }
    $obj = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    return $obj
}

function ConvertTo-SpecB64 { param($Object) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 6 -Compress))) }

function Send-GatePayload {
    # Zips the files and uploads them in chunks (Run Command parameter sizes are not
    # documented; chunking keeps each call small). ADR-029.
    param([hashtable]$Backend, [hashtable]$Files, [string]$TempDir)
    $stage = Join-Path $TempDir 'payload'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $stage
    foreach ($k in $Files.Keys) {
        $dest = Join-Path $stage $k
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
        # Byte copy: scripts are delivered exactly as committed (ASCII = UTF-8 without BOM, ADR-013).
        [System.IO.File]::WriteAllBytes($dest, [System.IO.File]::ReadAllBytes($Files[$k]))
    }
    $zip = Join-Path $TempDir 'payload.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
    $append = 'false'
    for ($i = 0; $i -lt $b64.Length; $i += $script:ChunkChars) {
        $part = $b64.Substring($i, [math]::Min($script:ChunkChars, $b64.Length - $i))
        $r = Invoke-GuestAction -Backend $Backend -Action 'PutChunk' -Params @{ Name = 'payload'; Data = $part; Append = $append }
        if (-not $r.ok) { throw ('upload failed: ' + $r.error) }
        $append = 'true'
    }
    $e = Invoke-GuestAction -Backend $Backend -Action 'Expand' -Params @{ Name = 'payload' }
    if (-not $e.ok) { throw ('expand failed: ' + $e.error) }
    return @($e.files)
}

# ---------------------------------------------------------------------------
# Spec and scenarios
# ---------------------------------------------------------------------------
function Read-Gate4Spec {
    param([Parameter(Mandatory = $true)][string]$PackagePath)
    $p = Join-Path $PackagePath 'gate4.json'
    if (-not (Test-Path -LiteralPath $p)) { throw ('gate4.json missing in {0} (see tools/vm/README.md)' -f $PackagePath) }
    $s = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable
    $errs = @()
    if ($s.packageId -ne (Split-Path -Leaf $PackagePath)) { $errs += 'packageId does not match the folder' }
    if (-not $s.scenarios -or @($s.scenarios).Count -eq 0) { $errs += 'scenarios is empty' }
    if ($s.ContainsKey('outdatedInstall')) {
        $o = $s.outdatedInstall
        if ($o.method -eq 'winget') { if (-not $o.id -or -not $o.version) { $errs += 'outdatedInstall winget needs id and version' } }
        elseif ($o.method -eq 'url') {
            if ($o.url -notmatch '^https://') { $errs += 'outdatedInstall url must be https' }
            if ($o.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { $errs += 'outdatedInstall url needs sha256' }
        } else { $errs += 'outdatedInstall.method must be winget or url' }
    }
    if ($errs.Count) { throw ('gate4.json invalid: ' + ($errs -join '; ')) }
    return $s
}

function Get-Gate4Target {
    # Target version for the on-disk check: 'catalog' asks the winget-pkgs lookup tool on the
    # host (Pattern A); anything else is a literal version.
    param([hashtable]$Spec, $DecisionRecord, [scriptblock]$CatalogLookup)
    $t = [string]$Spec.versionCheck.target
    if ($t -eq 'catalog') {
        if (-not $CatalogLookup) {
            $CatalogLookup = {
                param($id)
                $j = & python3 (Join-Path $script:Root 'tools/classify/winget_manifest_lookup.py') $id | ConvertFrom-Json
                if (-not $j.found) { throw ('catalog lookup found nothing for ' + $id) }
                $j.latestVersion
            }
        }
        $t = [string](& $CatalogLookup $DecisionRecord.install.wingetId)
    }
    return ConvertTo-Gate4Version $t
}

function ConvertTo-Gate4Version {
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts -join '.')
}

function Expand-Gate4Scenario {
    # Named scenarios become explicit setup/steps/checks by type and pattern; objects in the
    # spec are taken as they are.
    param([hashtable]$Spec, $DecisionRecord)
    $type = [string]$DecisionRecord.type
    $pattern = [string]$DecisionRecord.pattern
    $download = $pattern -in @('Browser', 'B1', 'B2', 'B3')
    $out = @()
    $successRemediate = @('REMEDIATED')
    $okAfter = @('UP_TO_DATE')
    if ($pattern -eq 'Browser') { $successRemediate += 'STAGED'; $okAfter += 'STAGED' }
    if ($type -eq 'vuln-remediation') { $successRemediate = @('MITIGATED', 'STAGED'); $okAfter = @('NOT_EXPOSED', 'STAGED') }
    $outdatedTok = if ($type -eq 'vuln-remediation') { 'EXPOSED' } else { 'OUTDATED' }
    $absentTok = if ($type -eq 'vuln-remediation') { 'NOT_APPLICABLE' } else { 'NOT_INSTALLED' }
    $common = @('logs-present', 'within-budget', 'system-64bit', 'single-status-line')
    foreach ($sc in @($Spec.scenarios)) {
        if ($sc -is [hashtable]) { $out += $sc; continue }
        switch ("$type/$sc") {
            { $_ -in @('app-update/main', 'vuln-remediation/main') } {
                $out += @{ name = 'main'; setup = @(@{ action = 'install-outdated' })
                    steps = @(@{ role = 'detect'; expect = @($outdatedTok); exit = 1 }, @{ role = 'remediate'; expect = $successRemediate; exit = 0 }, @{ role = 'detect'; expect = $okAfter; exit = 0 })
                    checks = @('version-at-least-target-unless-staged', 'no-staging-left') + $common }
            }
            { $_ -in @('app-update/absent', 'vuln-remediation/absent') } {
                $out += @{ name = 'absent'; setup = @(); steps = @(@{ role = 'detect'; expect = @($absentTok); exit = 0 }); checks = $common }
            }
            { $_ -in @('app-update/blocked-endpoint', 'vuln-remediation/blocked-endpoint') } {
                if ($download) {
                    $out += @{ name = 'blocked-endpoint'; setup = @(@{ action = 'install-outdated' }, @{ action = 'block-hosts' })
                        steps = @(@{ role = 'detect'; expect = @($outdatedTok); exit = 1 }, @{ role = 'remediate'; expect = @('FAILED', 'ERROR'); exit = 1 })
                        checks = @('version-unchanged', 'no-staging-left') + $common }
                } else {
                    $out += @{ name = 'blocked-endpoint'; setup = @(@{ action = 'install-outdated' }, @{ action = 'block-hosts' })
                        steps = @(@{ role = 'detect'; expect = @('NOT_DETERMINED'); exit = 0 })
                        checks = @('version-unchanged') + $common }
                }
            }
            { $_ -in @('app-update/tampered-installer', 'vuln-remediation/tampered-installer') } {
                if (-not $download) { $out += @{ name = 'tampered-installer'; notApplicable = 'winget verifies installer hashes itself; Pattern A has no installer trust step' }; break }
                $out += @{ name = 'tampered-installer'; setup = @(@{ action = 'install-outdated' })
                    steps = @(@{ role = 'detect'; expect = @($outdatedTok); exit = 1 }, @{ role = 'remediate-tampered'; expect = @('FAILED'); exit = 1 })
                    checks = @('version-unchanged', 'no-staging-left') + $common }
            }
            { $_ -in @('app-update/user-scope-only', 'vuln-remediation/user-scope-only') } {
                $out += @{ name = 'user-scope-only'; setup = @(@{ action = 'plant-user-scope' })
                    steps = @(@{ role = 'detect'; expect = @('SKIPPED_USER_SCOPE'); exit = 0 }); checks = $common }
            }
            'config-change/main' {
                $out += @{ name = 'main'; setup = @($Spec.driftSetup | ForEach-Object { @{ action = 'registry'; spec = $_ } })
                    steps = @(@{ role = 'detect'; expect = @('DRIFTED'); exit = 1 }, @{ role = 'remediate'; expect = @('REMEDIATED', 'PENDING_REBOOT'); exit = 0 }, @{ role = 'detect'; expect = @('COMPLIANT'); exit = 0 })
                    checks = @('registry-desired') + $common }
            }
            'config-change/compliant' {
                $out += @{ name = 'compliant'; setup = @($Spec.compliantSetup | ForEach-Object { @{ action = 'registry'; spec = $_ } })
                    steps = @(@{ role = 'detect'; expect = @('COMPLIANT'); exit = 0 }); checks = $common }
            }
            default { throw ('no built-in scenario {0} for type {1}; define it as an object in gate4.json' -f $sc, $type) }
        }
    }
    return , $out
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
function Get-StatusLine {
    param([string]$Stdout)
    $lines = @(([string]$Stdout) -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $status = @($lines | Where-Object { $_ -cmatch '^[A-Z][A-Z_]+ \| ' })
    return @{ lines = $lines.Count; statusLines = $status.Count; token = $(if ($status.Count) { ($status[0] -split ' \| ')[0] } else { '' }); text = $(if ($status.Count) { $status[0] } else { '' }) }
}

function Test-Gate4Step {
    param($Run, [hashtable]$Step)
    $a = @()
    $sl = Get-StatusLine $Run.stdout
    $a += @{ name = "$($Step.role): token in [$(@($Step.expect) -join ', ')]"; pass = ($sl.token -in @($Step.expect)); detail = $sl.text }
    $a += @{ name = "$($Step.role): exit code $($Step.exit)"; pass = ($Run.exitCode -eq $Step.exit); detail = "exit=$($Run.exitCode)" }
    $a += @{ name = "$($Step.role): not timed out"; pass = (-not $Run.timedOut); detail = "durationSec=$($Run.durationSec)" }
    return @{ assertions = $a; statusLine = $sl }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Gate4 {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][hashtable]$Backend,
        [string]$OutDir = '',
        [string[]]$Only = @(),
        [switch]$IncludeWindowsTests,
        [scriptblock]$CatalogLookup
    )
    $pkg = (Resolve-Path -LiteralPath $PackagePath).Path
    $id = Split-Path -Leaf $pkg
    $started = Get-Date
    if (-not $OutDir) { $OutDir = Join-Path $script:Root ('out/{0}/gate4-{1}' -f $id, $started.ToString('yyyyMMdd-HHmmss')) }
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    $tmp = Join-Path $OutDir 'tmp'
    $null = New-Item -ItemType Directory -Path $tmp -Force

    $result = [ordered]@{ gate = 'gate4'; package = $id; backend = $Backend.Name; status = 'FAIL'; started = $started.ToString('o'); finished = $null
        target = $null; environment = $null; scenarios = @(); notes = @() }
    try {
        $dr = Get-Content -LiteralPath (Join-Path $pkg 'decision-record.json') -Raw | ConvertFrom-Json
        $spec = Read-Gate4Spec -PackagePath $pkg
        $scenarios = Expand-Gate4Scenario -Spec $spec -DecisionRecord $dr
        if ($Only.Count) { $scenarios = @($scenarios | Where-Object { $_.name -in $Only }) }
        $target = $null
        if ($spec.ContainsKey('versionCheck')) { $target = Get-Gate4Target -Spec $spec -DecisionRecord $dr -CatalogLookup $CatalogLookup }
        $result.target = [string]$target

        # payload: the package scripts exactly as committed, a tampered remediation for the
        # tampered-installer scenario, the guest runner, and (optionally) Windows test suites.
        $files = @{ 'Start-ScriptRun.ps1' = (Join-Path $PSScriptRoot 'guest/Start-ScriptRun.ps1') }
        foreach ($r in @('detect', 'remediate')) {
            $f = Join-Path $pkg ('{0}.ps1' -f $r)
            if (Test-Path -LiteralPath $f) { $files["$r.ps1"] = $f }
        }
        if ($files.ContainsKey('remediate.ps1')) {
            $t = [System.IO.File]::ReadAllText($files['remediate.ps1'])
            $tampered = [regex]::Replace($t, '(?m)^\$EXPECTED_SIGNER_O\s*=.*$', "`$EXPECTED_SIGNER_O  = 'Gate4 Tampered Signer'")
            $tp = Join-Path $tmp 'remediate-tampered.ps1'
            [System.IO.File]::WriteAllText($tp, $tampered, (New-Object System.Text.UTF8Encoding($false)))
            $files['remediate-tampered.ps1'] = $tp
        }
        if ($IncludeWindowsTests) {
            $files['tests/helpers.ps1'] = Join-Path $script:Root '.claude/skills/intune-remediation/references/helpers.ps1'
            $files['tests/Mocks.ps1'] = Join-Path $script:Root 'tools/pester/Mocks.ps1'
            $files['tests/Helpers.Windows.Tests.ps1'] = Join-Path $script:Root 'tools/pester/helpers/Helpers.Windows.Tests.ps1'
        }

        $scenarioResults = @()
        $first = $true
        foreach ($sc in $scenarios) {
            $sr = [ordered]@{ name = $sc.name; status = 'FAIL'; reset = $null; steps = @(); assertions = @(); detail = '' }
            if ($sc.ContainsKey('notApplicable')) { $sr.status = 'NOT_APPLICABLE'; $sr.detail = $sc.notApplicable; $scenarioResults += $sr; continue }
            try {
                if ($Backend.CanRevert) {
                    $rs = & $Backend.Reset
                    $sr.reset = $rs
                    if (-not $rs.ok) { throw ('revert to baseline failed: ' + $rs.detail) }
                } elseif (-not $first) {
                    $sr.detail = 'backend cannot revert; scenario ran on a dirty VM'
                }
                $first = $false
                $info = Invoke-GuestAction -Backend $Backend -Action 'Info'
                if (-not $result.environment) {
                    $result.environment = [ordered]@{ edition = $info.edition; displayVersion = $info.displayVersion; osVersion = $info.osVersion
                        uiCulture = $info.uiCulture; psVersion = $info.psVersion; wingetFound = [bool]$info.wingetPath; pester5 = $info.pester5 }
                }
                $null = Send-GatePayload -Backend $Backend -Files $files -TempDir $tmp

                foreach ($su in @($sc.setup)) {
                    $act = $su.action
                    $res = switch ($act) {
                        'install-outdated' { Invoke-GuestAction $Backend 'InstallOutdated' @{ SpecB64 = (ConvertTo-SpecB64 $spec.outdatedInstall) } }
                        'block-hosts' { Invoke-GuestAction $Backend 'BlockHosts' @{ SpecB64 = (ConvertTo-SpecB64 @{ hosts = @($spec.blockHosts) }) } }
                        'plant-user-scope' { Invoke-GuestAction $Backend 'PlantUserScope' @{ SpecB64 = (ConvertTo-SpecB64 @{ relPath = $spec.userScope.relPath; from = $spec.userScope.plantFrom }) } }
                        'registry' { Invoke-GuestAction $Backend 'Registry' @{ SpecB64 = (ConvertTo-SpecB64 $su.spec) } }
                        default { throw ('unknown setup action ' + $act) }
                    }
                    if (-not $res.ok) {
                        if ($res.error -like 'NOT_RUN:*') { $sr.status = 'NOT_RUN'; $sr.detail = $res.error; break }
                        throw ('setup {0} failed: {1}' -f $act, $res.error)
                    }
                }
                if ($sr.status -eq 'NOT_RUN') { $scenarioResults += $sr; continue }

                $vpath = ''
                if ($spec.ContainsKey('versionCheck')) { $vpath = [string]$spec.versionCheck.path }
                $collectSpec = @{ packageId = $id; versionPath = $vpath }
                if ($spec.ContainsKey('registryCheck')) { $collectSpec.registry = $spec.registryCheck }
                $before = Invoke-GuestAction $Backend 'Collect' @{ SpecB64 = (ConvertTo-SpecB64 $collectSpec) }
                $staged = $false
                $i = 0
                foreach ($st in @($sc.steps)) {
                    $i++
                    $scriptName = if ($st.role -eq 'remediate-tampered') { 'remediate-tampered.ps1' } else { "$($st.role).ps1" }
                    $rr = Invoke-GuestAction $Backend 'Run' @{ Role = $st.role; Script = $scriptName; TimeoutSeconds = 600 }
                    if (-not $rr.ok) { throw ('run {0} failed: {1}' -f $st.role, $rr.error) }
                    $run = $rr.run
                    Set-Content -LiteralPath (Join-Path $OutDir ('{0}-{1}-{2}.stdout.txt' -f $sc.name, $i, $st.role)) -Value ([string]$run.stdout) -Encoding ascii
                    $t = Test-Gate4Step -Run $run -Step $st
                    if ($t.statusLine.token -eq 'STAGED') { $staged = $true }
                    $sr.steps += [ordered]@{ role = $st.role; token = $t.statusLine.token; exitCode = $run.exitCode; durationSec = $run.durationSec; timedOut = $run.timedOut
                        identitySid = $run.identitySid; is64 = $run.is64Process; psVersion = $run.psVersion; statusLines = $t.statusLine.statusLines; stdoutLines = $t.statusLine.lines }
                    $sr.assertions += $t.assertions
                }
                $after = Invoke-GuestAction $Backend 'Collect' @{ SpecB64 = (ConvertTo-SpecB64 $collectSpec) }
                foreach ($c in @($sc.checks)) {
                    $sr.assertions += switch ($c) {
                        'version-at-least-target-unless-staged' {
                            $v = ConvertTo-Gate4Version $after.fileVersion
                            if ($staged) { @{ name = 'on-disk version (staged: not required)'; pass = $true; detail = "fileVersion=$($after.fileVersion)" } }
                            else { @{ name = 'on-disk FileVersion >= target'; pass = ($null -ne $v -and $null -ne $target -and $v -ge $target); detail = "fileVersion=$($after.fileVersion) target=$target" } }
                        }
                        'version-unchanged' { @{ name = 'on-disk version unchanged'; pass = ($after.fileVersion -eq $before.fileVersion); detail = "$($before.fileVersion) -> $($after.fileVersion)" } }
                        'no-staging-left' { @{ name = 'no staging dir left'; pass = (@($after.stagingLeft).Count -eq 0); detail = (@($after.stagingLeft) -join ', ') } }
                        'logs-present' {
                            $roles = @($sc.steps | ForEach-Object { if ($_.role -eq 'remediate-tampered') { 'remediate' } else { $_.role } } | Sort-Object -Unique)
                            $missing = @($roles | Where-Object { $r = $_; -not (@($after.logs) | Where-Object { $_ -like ('IntuneRem_{0}_{1}_*.log' -f $id, $r) }) })
                            @{ name = 'IntuneRem logs present per role'; pass = ($missing.Count -eq 0); detail = ('missing: ' + ($missing -join ', ')) }
                        }
                        'within-budget' {
                            $slow = @($sr.steps | Where-Object { $null -eq $_.durationSec -or $_.durationSec -gt $script:Budget })
                            @{ name = "each run <= $($script:Budget) s"; pass = ($slow.Count -eq 0); detail = (@($sr.steps | ForEach-Object { "$($_.role)=$($_.durationSec)s" }) -join ' ') }
                        }
                        'system-64bit' {
                            $bad = @($sr.steps | Where-Object { $_.identitySid -ne $script:SystemSid -or -not $_.is64 })
                            @{ name = 'ran as SYSTEM in 64-bit PowerShell'; pass = ($bad.Count -eq 0); detail = (@($sr.steps | ForEach-Object { "$($_.identitySid)/64=$($_.is64)/ps=$($_.psVersion)" }) -join ' ') }
                        }
                        'single-status-line' {
                            $bad = @($sr.steps | Where-Object { $_.statusLines -ne 1 -or $_.stdoutLines -ne 1 })
                            @{ name = 'exactly one stdout line, a status line'; pass = ($bad.Count -eq 0); detail = (@($sr.steps | ForEach-Object { "$($_.role)=$($_.stdoutLines)/$($_.statusLines)" }) -join ' ') }
                        }
                        'registry-desired' {
                            @{ name = 'registry value matches desired'; pass = ([string]$after.registryValue -eq [string]$spec.registryCheck.value); detail = "value=$($after.registryValue)" }
                        }
                        default { throw ('unknown check ' + $c) }
                    }
                }
                $sr.status = if (@($sr.assertions | Where-Object { -not $_.pass }).Count -eq 0) { 'PASS' } else { 'FAIL' }
            } catch {
                $sr.status = 'ERROR'
                $sr.detail = $_.Exception.Message
            }
            $scenarioResults += $sr
        }

        if ($IncludeWindowsTests) {
            $pr = Invoke-GuestAction $Backend 'Pester' @{ SpecB64 = (ConvertTo-SpecB64 @{ paths = @('tests/Helpers.Windows.Tests.ps1') }) }
            $ws = [ordered]@{ name = 'windows-helper-tests'; status = 'FAIL'; detail = ''; assertions = @() }
            if (-not $pr.ok) { $ws.status = $(if ($pr.error -like 'NOT_RUN:*') { 'NOT_RUN' } else { 'ERROR' }); $ws.detail = $pr.error }
            else {
                $ws.assertions = @(@{ name = 'Windows helper tests'; pass = ($pr.failed -eq 0 -and $pr.passed -gt 0); detail = "passed=$($pr.passed) failed=$($pr.failed) skipped=$($pr.skipped)" })
                $ws.status = if ($pr.failed -eq 0 -and $pr.passed -gt 0) { 'PASS' } else { 'FAIL' }
                $ws.failures = $pr.failures
            }
            $scenarioResults += $ws
        }

        $result.scenarios = $scenarioResults
        $states = @($scenarioResults | ForEach-Object { $_.status })
        if ($states -contains 'FAIL' -or $states -contains 'ERROR') { $result.status = 'FAIL' }
        elseif ($states -contains 'NOT_RUN' -or -not $Backend.CanRevert -or @($states | Where-Object { $_ -eq 'PASS' }).Count -eq 0) {
            $result.status = 'INCOMPLETE'
            if (-not $Backend.CanRevert) { $result.notes += 'backend cannot revert to the baseline snapshot: results are not deliverable' }
        } else { $result.status = 'PASS' }
    } catch {
        $result.status = 'ERROR'
        $result.notes += $_.Exception.Message
    }
    $result.finished = (Get-Date).ToString('o')
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $json = $result | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $OutDir 'gate4.json') -Value $json -Encoding ascii
    return $result
}

Export-ModuleMember -Function Invoke-Gate4, Invoke-GuestAction, Send-GatePayload, Read-Gate4Spec, Get-Gate4Target, ConvertTo-Gate4Version, Expand-Gate4Scenario, Get-StatusLine, Test-Gate4Step
