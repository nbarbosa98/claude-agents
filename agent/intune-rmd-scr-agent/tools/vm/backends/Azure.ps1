<#
Gate 4 backend: Azure VM through the Azure CLI (az), run from the operator's Mac.

Verified behaviour (MicrosoftDocs/azure-compute-docs, fetched 2026-10-02):
- Action Run Command, RunPowerShellScript: `az vm run-command invoke --command-id
  RunPowerShellScript --scripts @file --parameters "name=value"`; scripts run as System on
  Windows; one script at a time; max 90 minutes; output limited to the last 4,096 bytes
  (articles/virtual-machines/windows/run-command.md).
- Snapshot to disk: `az disk create --source <snapshot id>`
  (articles/virtual-machines/scripts/create-managed-disk-from-snapshot.md).
- OS disk swap: `az vm stop`, `az vm update --os-disk <disk id>`, `az vm start`
  (articles/virtual-machines/linux/os-disk-swap.md).
UNVERIFIED (lab): the exact JSON shape of run-command output (parsed tolerantly: every
'message' field is concatenated and searched for GATE4 markers), Run Command parameter size
limits (payload is chunked), whether a Trusted Launch VM needs extra `az disk create`
arguments (config vm.azure.diskCreateExtraArgs), revert duration.

Safety: every call first checks that the signed-in subscription is the allowlisted one in
config/local.json (vm.azure.subscriptionId). Only disks this backend created (tag
intune-rmd-gate4=temp) are ever deleted. IDs are never written to results. ASCII only.
#>

function Invoke-AzJson {
    param([string[]]$AzArgs)
    $out = & az @AzArgs --only-show-errors -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('az {0} failed: {1}' -f ($AzArgs[0..1] -join ' '), ($out | Out-String).Trim()) }
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json
}

function Invoke-AzTsv {
    param([string[]]$AzArgs)
    $out = & az @AzArgs --only-show-errors -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('az {0} failed: {1}' -f ($AzArgs[0..1] -join ' '), ($out | Out-String).Trim()) }
    return ($out | Out-String).Trim()
}

function New-AzureGateBackend {
    param([Parameter(Mandatory = $true)]$VmConfig)
    $az = $VmConfig.azure
    foreach ($k in @('subscriptionId', 'resourceGroup', 'vmName', 'baselineSnapshot')) {
        if (-not $az.$k) { throw ('config vm.azure.{0} is required' -f $k) }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found; install it and run az login' }
    $guestScript = Join-Path $PSScriptRoot '../guest/GateGuest.ps1'
    $extra = @()
    if ($az.diskCreateExtraArgs) { $extra = @($az.diskCreateExtraArgs) }

    $assert = {
        $sub = Invoke-AzTsv @('account', 'show', '--query', 'id')
        if ($sub -ne $az.subscriptionId) { throw 'signed-in Azure subscription is not the allowlisted lab subscription (config vm.azure.subscriptionId); refusing' }
    }.GetNewClosure()

    return @{
        Name      = 'azure'
        CanRevert = $true
        Reset     = {
            & $assert
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $rg = $az.resourceGroup
            $vm = $az.vmName
            $snapId = Invoke-AzTsv @('snapshot', 'show', '-g', $rg, '-n', $az.baselineSnapshot, '--query', 'id')
            $diskName = 'gate4-os-' + (Get-Date).ToString('yyyyMMddHHmmss')
            $newId = Invoke-AzTsv (@('disk', 'create', '-g', $rg, '-n', $diskName, '--source', $snapId, '--tags', 'intune-rmd-gate4=temp', '--query', 'id') + $extra)
            $oldId = Invoke-AzTsv @('vm', 'show', '-g', $rg, '-n', $vm, '--query', 'storageProfile.osDisk.managedDisk.id')
            $null = Invoke-AzTsv @('vm', 'stop', '-g', $rg, '-n', $vm)
            $null = Invoke-AzTsv @('vm', 'update', '-g', $rg, '-n', $vm, '--os-disk', $newId, '--query', 'name')
            $null = Invoke-AzTsv @('vm', 'start', '-g', $rg, '-n', $vm)
            $tag = Invoke-AzTsv @('disk', 'show', '--ids', $oldId, '--query', 'tags."intune-rmd-gate4"')
            if ($tag -eq 'temp') { $null = Invoke-AzTsv @('disk', 'delete', '--ids', $oldId, '--yes', '--no-wait') }
            $deadline = (Get-Date).AddMinutes(15)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                $st = Invoke-AzTsv @('vm', 'get-instance-view', '-g', $rg, '-n', $vm, '--query', 'instanceView.vmAgent.statuses[0].displayStatus')
                if ($st -eq 'Ready') { $ready = $true; break }
                Start-Sleep -Seconds 15
            }
            $sw.Stop()
            return @{ ok = $ready; seconds = [math]::Round($sw.Elapsed.TotalSeconds); detail = $(if ($ready) { 'reverted to baseline' } else { 'VM agent not Ready within 15 minutes' }) }
        }.GetNewClosure()
        Guest     = {
            param([string]$Action, [hashtable]$Params)
            & $assert
            $p = @("Action=$Action")
            foreach ($k in $Params.Keys) { $p += ('{0}={1}' -f $k, $Params[$k]) }
            $r = Invoke-AzJson (@('vm', 'run-command', 'invoke', '-g', $az.resourceGroup, '-n', $az.vmName, '--command-id', 'RunPowerShellScript',
                    '--scripts', ('@' + $guestScript), '--parameters') + $p)
            return (@($r.value | ForEach-Object { $_.message }) -join "`n")
        }.GetNewClosure()
    }
}
