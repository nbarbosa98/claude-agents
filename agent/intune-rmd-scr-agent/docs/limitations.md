# Known limitations

Written as the project goes; finalised in Phase 9. Each item says what it affects and what
would remove it.

| # | Limitation | Effect | What would remove it |
|---|---|---|---|
| L1 | Gate 4 runs scripts from a SYSTEM scheduled task, not the Intune Management Extension | IME-specific behaviour (how it launches PowerShell, its timeout, output capture, retries) is not exercised before the pilot ring | Phase 5 pilot ring is the authoritative test; a diagnostic package there records the IME's PowerShell version and command line |
| L2 | `winget.exe` under SYSTEM is unsupported by Microsoft (ADR-016, owner's choice) | Pattern A can break on App Installer changes; failures surface as NOT_DETERMINED / FAILED, never as false success | Switch Pattern A to `Microsoft.WinGet.Client` (ADR-016 option a) |
| L3 | Platform execution timeout for Remediations is undocumented | The 540 s ceiling is a design choice, not a verified limit | Measure in the pilot ring |
| L4 | User-scope installs are reported, not fixed (D2) | Per-user copies stay outdated | A separate user-context package (out of scope for v1) |
| L5 | HKU is read for signed-in users only; offline profiles are covered by a path scan only | A per-user install registered only in an unloaded hive, without the expected exe path, is missed | Loading NTUSER.DAT hives (rejected as risky) |
| L6 | Gate 2 off Windows cannot mock some provider-specific cmdlet parameters | Those scenarios are WindowsOnly and only run in the VM | n/a (by design: PASS_PENDING_WINDOWS is not deliverable) |
| L7 | Gate 4 user-scope-only plants a copy of a system binary in an existing profile | Tests detection logic, not a real per-user installer | A real per-user installer run as that user |
| L8 | Lab scale | Results come from one VM and a small pilot group, not a fleet | Production rollout data (out of scope) |
| L9 | Microsoft Graph beta endpoints for Remediations | Beta APIs can change without notice | Re-verify at Phase 5 and on every /drift run |
| L10 | Vendors without a published hash | Trust rests on the Authenticode signer only (HR-08) | Vendor publishing hashes |
| L11 | Plan-hash approval is typed in chat and passed to `apply.py` by the model | The model could pass a hash the user never typed; the human gate is the Claude Code permission prompt on `tools/graph/write/` plus the hash check | A TTY prompt inside `apply.py` that the user answers directly (not possible through the Bash tool today) |
| L12 | `assign` replace-vs-merge semantics are undocumented (ADR-035) | A merge would leave stale assignments; apply detects and reports it (exit 1) but does not fix it | Observe once in the lab and record the result |
| L13 | No automatic rollback | A failed update leaves the tenant in the receipt's recorded state; previous content is saved in `out/deploy/<id>/backup-<hash>/` | A rollback plan type built from the backup |
