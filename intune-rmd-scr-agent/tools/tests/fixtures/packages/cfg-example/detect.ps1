<#
Package:   cfg-example
Type:      config-change
Role:      detect
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

# ===== Main =====
try {
    Initialize-Log -PackageId $PACKAGE_ID -Role 'detect'
    Write-RemediationLog -Message ('Start detect. PS {0}, 64-bit process: {1}' -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)

    $drift = New-Object System.Collections.ArrayList
    foreach ($e in $DESIRED) {
        if (-not (Test-DesiredStateEntry -Entry $e)) { $null = $drift.Add($e.Name) }
    }
    if ($drift.Count -eq 0) {
        Exit-WithCode -Token 'COMPLIANT' -Message ('{0} compliant' -f $SUBJECT) -Code 0
    }
    Write-RemediationLog -Message ('Drifted: ' + ($drift -join ', '))
    Exit-WithCode -Token 'DRIFTED' -Message ('{0} drifted: {1} setting(s): {2}' -f $SUBJECT, $drift.Count, ($drift -join ', ')) -Code 1
}
catch {
    if ($_.Exception.Message -like 'ExitCalled:*') { throw }
    $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace '[^\x20-\x7E]', '?')
    Write-RemediationLog -Level 'ERROR' -Message ('Unhandled: ' + $reason)
    Write-Host ('ERROR | {0} script error: {1}' -f $SUBJECT, $reason)
    exit 0
}
