<#
Package:   cfg-example
Type:      config-change
Role:      remediate
Contract:  1.0.0
Generated: fixture-composer
Summary:   Test fixture: desired-state registry value and service start type
#>

# ===== Constants (HR-04: every timeout is declared here; sum <= 540 s) =====
$PACKAGE_ID = 'cfg-example'
$SUBJECT    = 'Example App hardening'
$DESIRED = @(
    @{ Kind = 'Registry'; Path = 'HKLM:\SOFTWARE\ExampleVendor\ExampleApp'; Name = 'TelemetryLevel'; Type = 'DWord'; Value = 0 },
    @{ Kind = 'Service'; Name = 'ExampleSvc'; StartType = 'Disabled'; StopIfRunning = $false; AbsentIsCompliant = $true }
)
$REBOOT_REQUIRED = $false

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Unattended SYSTEM script: no interactive caller, -WhatIf/-Confirm have no meaning.')]
    param([Parameter(Mandatory = $true)][hashtable]$Entry)
    switch ($Entry.Kind) {
        'Registry' {
            $prior = Get-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
            $pv = '<absent>'
            if ($null -ne $prior) { $pv = [string]$prior.($Entry.Name) }
            Write-RemediationLog -Message ('ROLLBACK Registry {0}\{1} prior={2}' -f $Entry.Path, $Entry.Name, $pv)
            if (-not (Test-Path -LiteralPath $Entry.Path)) { $null = New-Item -Path $Entry.Path -Force }
            $null = New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -PropertyType $Entry.Type -Value $Entry.Value -Force
        }
        'Service' {
            $svc = Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue
            if ($null -eq $svc) { return }
            $prior = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Entry.Name) -Name Start -ErrorAction SilentlyContinue).Start
            Write-RemediationLog -Message ('ROLLBACK Service {0} priorStart={1}' -f $Entry.Name, $prior)
            Set-Service -Name $Entry.Name -StartupType $Entry.StartType
            if ($Entry.StartType -eq 'Disabled' -and $svc.Status -eq 'Running' -and $Entry.StopIfRunning) {
                Stop-Service -Name $Entry.Name -Force -ErrorAction Stop
            }
        }
        default { throw ('unsupported desired-state kind: ' + $Entry.Kind) }
    }
}

# ===== Main =====
$stagingDir = $null
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'remediate'
    Write-RemediationLog -Message ('Start remediate. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

    # HR-19: re-check state first; exit with the compliant token if nothing to do.
    $failing = @($DESIRED | Where-Object { -not (Test-DesiredStateEntry -Entry $_) })
    if ($failing.Count -eq 0) {
        Exit-WithCode -Token 'COMPLIANT' -Message ('{0} compliant' -f $SUBJECT) -Code 0
    }
    foreach ($e in $failing) {
        Set-DesiredStateEntry -Entry $e
    }
    $still = @($DESIRED | Where-Object { -not (Test-DesiredStateEntry -Entry $_) })
    if ($still.Count -gt 0) {
        Exit-WithCode -Token 'FAILED' -Message ('{0} change failed: {1} setting(s) still drifted' -f $SUBJECT, $still.Count) -Code 1
    }
    if ($REBOOT_REQUIRED) {
        Exit-WithCode -Token 'PENDING_REBOOT' -Message ('{0} change applied. Waiting for reboot' -f $SUBJECT) -Code 0
    }
    Exit-WithCode -Token 'REMEDIATED' -Message ('{0} remediated: {1} setting(s) corrected' -f $SUBJECT, $failing.Count) -Code 0
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
