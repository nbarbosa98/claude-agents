---
name: intune-remediation
description: Knowledge base for generating and reviewing Intune Remediation script pairs for a Windows-only fleet (app updates, vulnerability remediation, config changes, audits, general). Loaded by the generator subagents and the reviewer. Not for deployment; deployment is /deploy.
user-invocable: false
---

# Intune Remediation knowledge base

Scripts run under the Intune Management Extension as SYSTEM, 64-bit, and must be
Windows PowerShell 5.1 compatible and ASCII-only. Every external fact used here is
listed with its source in [references/sources.md](references/sources.md).

## 1. Pick the reference for the job

| Script type | Read |
|---|---|
| app-update | [references/type-app-update.md](references/type-app-update.md) |
| vuln-remediation | [references/type-vuln-remediation.md](references/type-vuln-remediation.md) (plus type-app-update.md when the fix is an update) |
| config-change | [references/type-config-change.md](references/type-config-change.md) |
| audit | [references/type-audit.md](references/type-audit.md) |
| general | [references/type-general.md](references/type-general.md) |

Always also read:

- [references/contract.md](references/contract.md): allowed status tokens and exit codes (generated from `contract/stdout.json`; the JSON wins if they ever differ).
- [references/hard-rules.md](references/hard-rules.md): rules HR-01 to HR-21. Every generated script must satisfy all that apply.
- [references/skeleton.md](references/skeleton.md): the mandatory section order and the two skeleton templates in `references/templates/`.
- [references/helpers.ps1](references/helpers.ps1): canonical helper functions. Copy the ones a script uses verbatim.
- Worked examples that pass Gates 1 and 2: `tools/tests/fixtures/src/<id>/` (constants and
  bodies) and `tools/tests/fixtures/packages/<id>/` (composed): `upd-example` (Pattern A),
  `upd-exampleb1` (B1), `cfg-example` (config-change), `aud-example` (audit).

On demand:

- [references/platform.md](references/platform.md): verified Intune Remediations platform facts.
- [references/decision-record.md](references/decision-record.md): schema of `decision-record.json`.
- [references/failure-modes.md](references/failure-modes.md): known failure modes and their signatures.
- [references/intune-settings.md](references/intune-settings.md): the Intune settings table every package README contains.
- [references/review-checklist.md](references/review-checklist.md): reviewer perspectives and report format.

## 2. Hard-rule index

| ID | Rule (full text in hard-rules.md) | Checked by |
|---|---|---|
| HR-01 | ASCII only | Gate 1 |
| HR-02 | One status line, token allowed for type and script, exit code per contract | Gate 1, Gate 3 |
| HR-03 | Status only via `Exit-WithCode`; raw `exit` only inside it and the outer catch; outer catch rethrows `ExitCalled:*` | Gate 1 |
| HR-04 | Constants block declares every `$TIMEOUT_*`; sum <= 540 s | Gate 1 |
| HR-05 | Every wait and request is bounded | Gate 1 |
| HR-06 | No user-profile environment variables | Gate 1 |
| HR-07 | Installers staged only via `New-SecureStagingDir`, removed in `finally` | Gate 1, Gate 4 |
| HR-08 | `Test-InstallerTrust` immediately before any installer runs | Gate 1, Gate 3 |
| HR-09 | Machine scope only; user-scope-only installs report `SKIPPED_USER_SCOPE` | Gate 2, Gate 4 |
| HR-10 | Logs in the IME Logs folder, `IntuneRem_` prefix, prefix-scoped pruning | Gate 1 |
| HR-11 | Windows PowerShell 5.1 syntax only | Gate 1 |
| HR-12 | Versions compared as normalised `[version]` objects; trust order | Gate 1, Gate 3 |
| HR-13 | Never claim a fix that is not verified (`STAGED`, `PENDING_REBOOT`) | Gate 3, Gate 4 |
| HR-14 | Installer `Start-Process` uses `-NoNewWindow -PassThru` and a bounded wait | Gate 1 |
| HR-15 | winget rules (path, flags, currency by version compare, `--include-unknown` parity) | Gate 1 |
| HR-16 | Audit scripts change nothing | Gate 1 |
| HR-17 | Config-change guardrail list | Gate 3 |
| HR-18 | Output <= 512 chars, no personal data | Gate 1, Gate 3 |
| HR-19 | Remediation re-checks state first and is idempotent | Gate 2, Gate 3 |
| HR-20 | Never reboot, never close user apps | Gate 1, Gate 3 |
| HR-21 | Unknown state: `NOT_DETERMINED`, exit 0 | Gate 2, Gate 3 |

## 3. Output of a generator

Write exactly these files into `packages/<package-id>/`:

1. `detect.ps1`
2. `remediate.ps1` (not for audit)
3. `README.md` with these sections, in order: `## Summary`, `## Type and pattern`,
   `## Evidence`, `## Status tokens`, `## Intune settings`, `## Time budget`,
   `## Known failure modes`, `## Rollback`, `## UNVERIFIED items`.

`packages/<package-id>/decision-record.json` is written by the classifier (app-update,
vuln-remediation) or by the generator from the orchestrator's brief (other types). The
generator never edits evidence in it.

`<package-id>`: lowercase letters, digits and hyphens, max 49 chars, and prefixed by type:
`upd-`, `vuln-`, `cfg-`, `aud-`, `gen-` (for example `upd-7zip`).

## 4. When to stop and hand back

Stop and return a question to the orchestrator, instead of generating, when:

- the decision record has `confidence: low` or any `openQuestions`;
- a needed fact is not in the decision record or a reference, and cannot be cited;
- the request fits a different script type;
- a config-change guardrail (HR-17) would be crossed.
