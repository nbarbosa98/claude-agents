<!-- GENERATED from contract/stdout.json by tools/contract/build_contract_doc.py. Do not edit. -->
# Stdout contract v1.0.0

Single source of truth for status tokens, exit codes and which script types and roles may emit them. Consumed by the linter (Gate 1), the reviewer (Gate 3), ops-agent triage and tools/contract/build_contract_doc.py. Changes need explicit owner approval.

## Format

- Line: `<TOKEN> | <message>` (separator ` | `)
- Emitter: Exit-WithCode (Write-Host, then exit). Exactly one status line per run.
- Max line length: 512 characters (platform limit 2048; MicrosoftDocs/memdocs intune/device-management/tools/deploy-remediations.md @4b5429d, 'Script requirements' (2,048 characters; remediation runs only on detection exit 1))
- Placeholders: {Name}: filled by the script at run time. Subject means the app, setting group or check name declared in the package constants.

## Scripts per type

| Type | Scripts |
|---|---|
| app-update | detect, remediate |
| vuln-remediation | detect, remediate |
| config-change | detect, remediate |
| audit | detect |
| general | detect, remediate |

## Type: app-update

| Token | Script | Exit | Message template | Meaning |
|---|---|---|---|---|
| `NOT_INSTALLED` | detect | 0 | `{AppName} not found` | No machine-scope or user-scope install was found. In remediation: the app disappeared since detection; nothing to do. |
| `NOT_INSTALLED` | remediate | 0 | `{AppName} not found` | No machine-scope or user-scope install was found. In remediation: the app disappeared since detection; nothing to do. |
| `UP_TO_DATE` | detect | 0 | `{AppName} {InstalledVersion} is up to date` | Installed version is at least the target version. In remediation: state was already compliant, nothing changed. |
| `UP_TO_DATE` | remediate | 0 | `{AppName} {InstalledVersion} is up to date` | Installed version is at least the target version. In remediation: state was already compliant, nothing changed. |
| `OUTDATED` | detect | 1 | `{AppName} {InstalledVersion} is outdated. Target {TargetVersion}` | Installed version is below the target version; remediation will run. |
| `SKIPPED_USER_SCOPE` | detect | 0 | `{AppName} found in user scope only. Skipped` | Only per-user installs exist. A machine-scope remediation cannot fix them (ADR-012, D2). |
| `SKIPPED_USER_SCOPE` | remediate | 0 | `{AppName} found in user scope only. Skipped` | Only per-user installs exist. A machine-scope remediation cannot fix them (ADR-012, D2). |
| `STAGED` | detect | 0 | `{AppName} update staged. Waiting for app restart` | A newer version is staged and becomes active when the app restarts. The app is NOT patched on disk yet (ADR-011, D1). |
| `STAGED` | remediate | 0 | `{AppName} update staged. Waiting for app restart` | A newer version is staged and becomes active when the app restarts. The app is NOT patched on disk yet (ADR-011, D1). |
| `REMEDIATED` | remediate | 0 | `{AppName} updated to {NewVersion}` | Change applied AND verified by a post-check. |
| `PENDING_REBOOT` | detect | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `PENDING_REBOOT` | remediate | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `NOT_DETERMINED` | detect | 0 | `{Subject} state not determined: {Reason}` | State could not be established (source unreachable, tool missing, unparseable version). Fail-safe: exit 0, no remediation (ADR-015). |
| `FAILED` | remediate | 1 | `{Subject} update to {TargetVersion} failed: {Reason}` | Remediation attempted and did not reach the desired state, or a trust check refused the installer. For non-update types the message uses 'change failed' wording: see messageTemplateByType. |
| `ERROR` | detect | 0 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |
| `ERROR` | remediate | 1 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |

## Type: vuln-remediation

| Token | Script | Exit | Message template | Meaning |
|---|---|---|---|---|
| `SKIPPED_USER_SCOPE` | detect | 0 | `{AppName} found in user scope only. Skipped` | Only per-user installs exist. A machine-scope remediation cannot fix them (ADR-012, D2). |
| `SKIPPED_USER_SCOPE` | remediate | 0 | `{AppName} found in user scope only. Skipped` | Only per-user installs exist. A machine-scope remediation cannot fix them (ADR-012, D2). |
| `STAGED` | detect | 0 | `{AppName} update staged. Waiting for app restart` | A newer version is staged and becomes active when the app restarts. The app is NOT patched on disk yet (ADR-011, D1). |
| `STAGED` | remediate | 0 | `{AppName} update staged. Waiting for app restart` | A newer version is staged and becomes active when the app restarts. The app is NOT patched on disk yet (ADR-011, D1). |
| `MITIGATED` | remediate | 0 | `{AppName} {CveIds} mitigated` | Exposure closed AND verified by a post-check. |
| `NOT_APPLICABLE` | detect | 0 | `{Subject} not present. Not applicable` | The software or component the package targets is absent. |
| `NOT_APPLICABLE` | remediate | 0 | `{Subject} not present. Not applicable` | The software or component the package targets is absent. |
| `NOT_EXPOSED` | detect | 0 | `{AppName} not exposed to {CveIds}` | Present but outside the affected range, or the mitigation is in place. |
| `NOT_EXPOSED` | remediate | 0 | `{AppName} not exposed to {CveIds}` | Present but outside the affected range, or the mitigation is in place. |
| `EXPOSED` | detect | 1 | `{AppName} {InstalledVersion} exposed to {CveIds}` | Inside the affected range and not mitigated; remediation will run. |
| `PENDING_REBOOT` | detect | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `PENDING_REBOOT` | remediate | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `NOT_DETERMINED` | detect | 0 | `{Subject} state not determined: {Reason}` | State could not be established (source unreachable, tool missing, unparseable version). Fail-safe: exit 0, no remediation (ADR-015). |
| `FAILED` | remediate | 1 | `{AppName} {CveIds} remediation failed: {Reason}` | Remediation attempted and did not reach the desired state, or a trust check refused the installer. For non-update types the message uses 'change failed' wording: see messageTemplateByType. |
| `ERROR` | detect | 0 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |
| `ERROR` | remediate | 1 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |

## Type: config-change

| Token | Script | Exit | Message template | Meaning |
|---|---|---|---|---|
| `REMEDIATED` | remediate | 0 | `{Subject} remediated: {Detail}` | Change applied AND verified by a post-check. |
| `COMPLIANT` | detect | 0 | `{Subject} compliant` | Every desired-state entry matches. |
| `COMPLIANT` | remediate | 0 | `{Subject} compliant` | Every desired-state entry matches. |
| `DRIFTED` | detect | 1 | `{Subject} drifted: {DriftCount} setting(s): {DriftNames}` | At least one desired-state entry differs; remediation will run. |
| `PENDING_REBOOT` | detect | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `PENDING_REBOOT` | remediate | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `NOT_DETERMINED` | detect | 0 | `{Subject} state not determined: {Reason}` | State could not be established (source unreachable, tool missing, unparseable version). Fail-safe: exit 0, no remediation (ADR-015). |
| `FAILED` | remediate | 1 | `{Subject} change failed: {Reason}` | Remediation attempted and did not reach the desired state, or a trust check refused the installer. For non-update types the message uses 'change failed' wording: see messageTemplateByType. |
| `ERROR` | detect | 0 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |
| `ERROR` | remediate | 1 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |

## Type: audit

| Token | Script | Exit | Message template | Meaning |
|---|---|---|---|---|
| `AUDIT_CLEAN` | detect | 0 | `{Subject} audit clean: {Summary}` | No finding. |
| `AUDIT_FINDING` | detect | 1 | `{Subject} audit finding: {Summary}` | Finding present. No remediation script exists, so nothing changes on the device. |
| `NOT_DETERMINED` | detect | 0 | `{Subject} state not determined: {Reason}` | State could not be established (source unreachable, tool missing, unparseable version). Fail-safe: exit 0, no remediation (ADR-015). |
| `ERROR` | detect | 0 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |

## Type: general

| Token | Script | Exit | Message template | Meaning |
|---|---|---|---|---|
| `REMEDIATED` | remediate | 0 | `{Subject} remediated: {Detail}` | Change applied AND verified by a post-check. |
| `NOT_APPLICABLE` | detect | 0 | `{Subject} not present. Not applicable` | The software or component the package targets is absent. |
| `NOT_APPLICABLE` | remediate | 0 | `{Subject} not present. Not applicable` | The software or component the package targets is absent. |
| `COMPLIANT` | detect | 0 | `{Subject} compliant` | Every desired-state entry matches. |
| `COMPLIANT` | remediate | 0 | `{Subject} compliant` | Every desired-state entry matches. |
| `NONCOMPLIANT` | detect | 1 | `{Subject} noncompliant: {Detail}` | General-type issue found; remediation will run. |
| `PENDING_REBOOT` | detect | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `PENDING_REBOOT` | remediate | 0 | `{Subject} change applied. Waiting for reboot` | Change is written but only takes effect after a reboot. Never reported as fixed. |
| `NOT_DETERMINED` | detect | 0 | `{Subject} state not determined: {Reason}` | State could not be established (source unreachable, tool missing, unparseable version). Fail-safe: exit 0, no remediation (ADR-015). |
| `FAILED` | remediate | 1 | `{Subject} change failed: {Reason}` | Remediation attempted and did not reach the desired state, or a trust check refused the installer. For non-update types the message uses 'change failed' wording: see messageTemplateByType. |
| `ERROR` | detect | 0 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |
| `ERROR` | remediate | 1 | `{Subject} script error: {Reason}` | Unhandled exception caught by the outer catch. Detection exits 0 (fail-safe, ADR-015); remediation exits 1. Always a script-defect signal for ops-agent. |
