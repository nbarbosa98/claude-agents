# Gate 4: execution harness (lab VM)

Runs a package's scripts on a real Windows VM, as SYSTEM, in 64-bit Windows PowerShell,
through a one-shot scheduled task with a hard kill at 600 s, and checks the results.

```
pwsh -NoProfile -File tools/vm/Invoke-VmGate.ps1 -PackagePath packages/<id> [-Backend azure|local]
     [-Only main,absent] [-IncludeWindowsTests]
```

Result: `out/<id>/gate4-<timestamp>/gate4.json`, plus the stdout of every run.
Status: `PASS`; `FAIL` (an assertion failed or a scenario errored); `INCOMPLETE` (a scenario
could not run, or the backend cannot revert to the baseline). Only `PASS` is deliverable.

## How it works

| Piece | Runs on | Role |
|---|---|---|
| `Invoke-VmGate.ps1`, `Gate4.psm1` | your Mac (PowerShell 7) | scenarios, upload, assertions, result file |
| `backends/Azure.ps1` | your Mac (Azure CLI) | snapshot revert, Run Command transport |
| `backends/Local.ps1` | an elevated shell on Windows | same protocol, no revert (debugging only) |
| `guest/GateGuest.ps1` | the VM, as SYSTEM | setup actions, scheduled-task runs, collection |
| `guest/Start-ScriptRun.ps1` | the VM, scheduled task as SYSTEM | runs one script, 600 s kill, captures stdout and exit code |
| `guest/Initialize-GateVm.ps1` | the VM, once | installs Pester 5, reports winget, edition, language, profiles |

Per scenario: revert the VM to the `baseline` snapshot, upload the scripts (byte for byte,
ASCII = UTF-8 without BOM, ADR-013), run the setup (install the outdated version, block
hosts, plant a user-scope copy, set registry drift), run the steps, collect the on-disk
state, and assert.

### Scenarios (`packages/<id>/gate4.json`)

| Name | app-update / vuln | Asserts |
|---|---|---|
| `main` | install outdated, detect, remediate, detect | OUTDATED/1, REMEDIATED (STAGED for Browser)/0, UP_TO_DATE or STAGED/0; on-disk FileVersion >= target unless staged; no staging dir left |
| `absent` | detect on a clean VM | NOT_INSTALLED/0 (vuln: NOT_APPLICABLE) |
| `blocked-endpoint` | outdated + outbound block of `blockHosts` | Pattern A: detection NOT_DETERMINED/0; download patterns: remediation FAILED or ERROR/1; version unchanged |
| `tampered-installer` | remediation with the expected signer altered on the host | FAILED/1, version unchanged, staging removed (not applicable to Pattern A: winget checks hashes itself) |
| `user-scope-only` | a versioned PE planted in an existing user profile | SKIPPED_USER_SCOPE/0 |
| config-change `main` / `compliant` | registry drift from `driftSetup` / `compliantSetup` | DRIFTED, REMEDIATED, COMPLIANT; registry value checked |

Every step also asserts: exit code, exactly one stdout line that is a status line, not timed
out, duration <= 540 s, ran as `S-1-5-18` in a 64-bit process, and IntuneRem logs present.
Custom scenarios can be written as objects in `gate4.json` (`setup`, `steps`, `checks`).

Example: `tools/tests/fixtures/src/upd-example/gate4.json`.

## One-time Azure setup (you run these; nothing here creates resources for you)

Facts verified in MicrosoftDocs/azure-compute-docs: Run Command (`RunPowerShellScript`) runs
as System, one script at a time, at most 90 minutes, with output limited to the last 4,096
bytes; an OS disk can be swapped with `az vm stop`, `az vm update --os-disk`, `az vm start`;
`az disk create --source <snapshot>` creates a disk from a snapshot.

1. **VM:** Windows 11 Enterprise, **x64**, a small general-purpose size, in a lab resource
   group in your subscription. Find the image with
   `az vm image list --publisher <publisher> --all -o table` (or the portal); the publisher
   and offer names are **UNVERIFIED** here. Confirm that your licensing allows Windows 11
   Enterprise in Azure (**UNVERIFIED** here; check with your licensing terms). Do **not**
   enrol it in Intune (ADR-017).
2. Sign in once over RDP with a local user, so a user profile exists (the user-scope-only
   scenario plants into it) and App Installer (winget) is registered. Update App Installer
   if winget is missing.
3. Run the preparation script as SYSTEM and read its report:
   `az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript --scripts @tools/vm/guest/Initialize-GateVm.ps1`
4. Stop the VM and snapshot its OS disk as the baseline:
   `az snapshot create -g <rg> -n baseline --source <os-disk-id>`.
5. Fill in `config/local.json` `vm.azure` (subscriptionId, resourceGroup, vmName,
   baselineSnapshot). The backend refuses to run when the signed-in subscription differs.
6. If the VM uses Trusted Launch and disk creation fails, put the extra
   `az disk create` arguments it needs in `vm.azure.diskCreateExtraArgs` (**UNVERIFIED**).

Cleanup: the backend deletes only OS disks it created itself (tag `intune-rmd-gate4=temp`).
Stop or deallocate the VM when you are not testing; it costs money while running.

## Fidelity (see docs/limitations.md)

A scheduled task as SYSTEM is not the Intune Management Extension. Gate 4 proves the scripts
behave correctly on real Windows under SYSTEM; the pilot ring (Phase 5) is the authoritative
end-to-end test. Run Command's own latency (tens of seconds per call, **UNVERIFIED**) makes a
full run take a while; revert time is **UNVERIFIED** and is recorded in every result.

## Tests

`tools/vm/tests/Gate4.Tests.ps1` drives the whole host side against an in-process fake VM
(`tests/FakeBackend.ps1`): passing scenarios, chunked result transfer, and broken behaviour
(no version change, leftover staging, extra output, non-SYSTEM, over budget, failed revert,
missing profile, no revert) that must not pass.
