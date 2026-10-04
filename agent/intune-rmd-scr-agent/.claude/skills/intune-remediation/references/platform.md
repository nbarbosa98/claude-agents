# Intune Remediations platform facts

Source for all rows unless stated: MicrosoftDocs/memdocs
`intune/device-management/tools/deploy-remediations.md` at commit 4b5429d (line numbers
in brackets).

| Fact | Status |
|---|---|
| A package is a detection script only, or a detection plus a remediation script [66] | Verified |
| The remediation script runs only when detection exits 1; any other exit code means no remediation [67, 148] | Verified |
| Empty detection output results in an "issue isn't found" state [148] | Verified |
| Maximum output size: 2,048 characters [70] | Verified |
| Scripts must be encoded in UTF-8; not UTF-8 BOM when "Enforce script signature check" is on [68-69] | Verified |
| With signature check on, the script runs under the device's execution policy; without it, under Bypass [71-74] | Verified |
| Schedule options: Once, Hourly (every n hours, n < 24), Daily at a time; device local time unless "Use UTC"; missed runs run when the device is next online [97-110] | Verified |
| Licensing: device users need Windows Enterprise E3/E5 or another listed licence [49-51] | Verified |
| RBAC: Remediations need permissions under the "Device configurations" category [59] | Verified |
| Microsoft's samples write status with `Write-Host` and use `exit 0` / `exit 1` (`ref-remediation-scripts.md` [51-58]) | Verified |
| Platform execution timeout for a Remediations script | **UNVERIFIED** - not in the docs; measured in the lab (Phase 3) |
| PowerShell host version the IME uses | **UNVERIFIED** - not in the docs; this project targets 5.1 (ADR-009) |
| How the IME invokes the script (`-File` or otherwise) | **UNVERIFIED** - matters for `exit` semantics; lab (Phase 3) |
| Whether "Collect diagnostics" includes custom files in the IME Logs folder | **UNVERIFIED** - lab (Phase 5) |
