# Decision log

ADR-style. Each entry: decision, alternatives, tradeoff, source, status.
Status values: `ACCEPTED` (owner confirmed), `DEFAULT` (default applied, owner has
not objected, can be revisited), `PROPOSED` (awaiting owner), `OPEN`.

---

## ADR-001 Project placement

- **Decision:** subfolder `intune-rmd-scr-agent/` in the `claude-agents` repo, opened
  as its own project root in Claude Code.
- **Alternatives:** separate repo; plugin in the marketplace.
- **Tradeoff:** a plugin cannot carry `.claude/settings.json` permission rules, which
  would remove the `ask` layer for deploy/promote. A separate repo is cleanest but
  needs to be created outside this session. The subfolder can be extracted later
  with `git subtree split`, which keeps history. Cost: the sanitizer's history scan
  also covers the rest of this repo.
- **Status:** ACCEPTED.

## ADR-002 Build from scratch

- **Decision:** the original `inputs/*.SKILL.md` files do not exist. The knowledge base
  (skill, references, contract) is written from scratch and every external fact is
  verified against official sources at build time.
- **Consequence:** the Phase 1 "rule-coverage table against the original skill" has
  no original to map. It is replaced by a **source-coverage table**: every rule maps
  to a verified source URL, or is marked as a design choice, or `UNVERIFIED`.
- **Consequence:** D1 and D4 existed to stay compatible with scripts already in
  production. There are none, so compatibility is no longer a constraint (see ADR-011).
- **Status:** ACCEPTED.

## ADR-003 Orchestrator plus specialist subagents

- **Decision:** the main thread runs as the named agent `intune-rmd-scr-agent`
  (via `"agent": "intune-rmd-scr-agent"` in project `.claude/settings.json`). It routes
  each request to one generator subagent, runs the gates and drives deployment setup.
- **Subagents and why each exists:**

  | Subagent | Role | Why separate |
  |---|---|---|
  | `app-update-agent` | Generator: keep apps current | Loads only the app-update references; keeps the orchestrator context small |
  | `vuln-remediation-agent` | Generator: close a named exposure (CVE / Defender recommendation) | Needs evidence handling (advisory, fixed version) the other types do not |
  | `config-change-agent` | Generator: enforce a desired setting state | Must first test whether a configuration profile is the better tool |
  | `audit-agent` | Generator: detection-only reporting | Read-only by construction; different contract (no remediation script) |
  | `general-agent` | Generator: anything else | Catch-all with the strictest review; re-routes if another type fits |
  | `classifier` | Evidence record for app-update and vuln (winget manifest, vendor probe) | Read-only tools; isolation keeps generation concerns from biasing the classification |
  | `reviewer` (shared) | Gate 3 independent review for all five types | Fresh context; receives only scripts, contract and references, never generator reasoning |
  | `ops-agent` | Read-only tenant view: list all remediations, run states, success rates, troubleshooting | Only component with Graph read; never writes |

- **Generators cannot spawn subagents** (`Agent` omitted from their `tools`).
- **Source:** https://code.claude.com/docs/en/sub-agents (main thread as a named agent
  via `--agent` or the `agent` setting; subagents may spawn subagents up to 3 levels
  unless `Agent` is removed from `tools`). Read via a summarising fetch; exact wording
  to be re-checked when the agent files are written.
- **Status:** ACCEPTED (N1 shared reviewer, N2 option a).

## ADR-004 Routing rules

- **Decision (PROPOSED, see `docs/script-types.md` section 2):**
  - OS cumulative updates: refuse, recommend Windows Update for Business / Autopatch.
  - Microsoft 365 Apps (Click-to-Run): refuse, recommend the M365 Apps update channels.
  - Settings that a configuration profile (Settings Catalog / CSP) can enforce:
    `config-change-agent` warns and recommends the profile first; a script is built
    only if the owner still wants it, and the decision is recorded.
  - A CVE fixed by an app update: `vuln-remediation-agent` owns the package, and reuses
    the app-update detection/remediation blocks rather than a second update code path.
  - Ambiguous requests: the orchestrator asks. It never guesses a type.
- **Status:** PROPOSED.

## ADR-005 Auth: the user's own credentials (delegated)

- **Decision:** all Graph calls (Entra group search, deploy, read) use delegated
  auth with the signed-in user's credentials. No app-only certificate.
- **Why:** actions are attributed to the user in the audit log; effective rights are
  the intersection of the consented scopes and the user's Intune/Entra roles; no
  certificate to store.
- **Costs:** interactive sign-in; token expiry; device-code flow is often blocked by
  Conditional Access (fallback: interactive browser sign-in on the operator's Mac).
- **Intune role requirement (verified):** Remediations need permissions under the
  **Device configurations** category of the user's Intune role. Source:
  MicrosoftDocs/memdocs `intune/device-management/tools/deploy-remediations.md`
  (commit 4b5429d), section "Permissions".
- **UNVERIFIED:** exact delegated Graph scope names for deviceHealthScripts write,
  run-state read and group search. Verified in Phase 5.
- **Where it runs:** on the operator's Mac. The cloud build container cannot reach
  `graph.microsoft.com` (network policy) and has no access to the user's sign-in.
- **Status:** ACCEPTED (N4).

## ADR-006 Guided deployment with plan-hash approval

- **Decision:** the user names a group; the agent searches Entra and shows candidates
  (display name, object ID, assigned vs dynamic, member count, users vs devices). It
  never picks between several matches on its own. Setup then confirms schedule,
  run context, 64-bit, signature check, and create vs update (with a diff). The
  result is a plan; apply requires the user to type the plan's short hash.
- **Status:** ACCEPTED (N5).

## ADR-007 Rings

- **Decision:** keep pilot and broad rings. The user names both groups during setup.
  `/promote` runs only when the promotion criteria in config are met, and still
  requires plan-hash approval.
- **Same-group rule:** if the user names the same group for pilot and broad, the
  agent stops and asks for explicit confirmation that they want to deploy to that
  whole group at once with no pilot stage. Without that confirmation, nothing is
  deployed. The confirmation is recorded in the plan (and therefore in its hash).
- **Status:** ACCEPTED (N6).

## ADR-008 Tenant-wide read scope

- **Decision:** `ops-agent` may read every remediation in the tenant (including ones
  it did not create), but is read-only. Any fix it proposes goes through the full
  generation pipeline and `/deploy` approval. Lab tenant only, enforced by the tenant
  guard hook against the allowlist in `config/local.json`.
- **Status:** DEFAULT (N7 not answered explicitly; this restates the original hard rule).

## ADR-009 Target platform

- **Decision:** Windows-only fleet. Scripts target **Windows PowerShell 5.1** syntax
  and cmdlets, run as SYSTEM in 64-bit PowerShell.
- **Why 5.1:** the conservative choice. The IME's PowerShell host version is not
  stated in the Remediations docs (**UNVERIFIED**; confirmed in the lab in Phase 3).
  Scripts that are 5.1-compatible also run on 7, not the reverse.
- **Note:** the Remediations docs' own tutorial sets "Run script in 64-bit
  PowerShell: No" for its sample. This project deliberately sets 64-bit = Yes so that
  registry and `Program Files` views are native. Source: deploy-remediations.md
  (commit 4b5429d), lines 156-157.
- **Status:** ACCEPTED (Windows-only); 5.1 is DEFAULT.

## ADR-010 Execution environment split

- **Decision:** this cloud container builds and runs Gate 1 (lint) and local Pester
  (Gate 2). Gate 4 (VM), Graph sign-in, deployment and ops run from Claude Code on the
  operator's Mac.
- **Why:** the container cannot reach the lab VM, `graph.microsoft.com`,
  `learn.microsoft.com` or `www.powershellgallery.com`.
- **Doc verification method:** official docs source repos, cloned read-only:
  `MicrosoftDocs/memdocs` (Intune) and `microsoftgraph/microsoft-graph-docs-contrib`
  (Graph). Citations name the repo path and commit.
- **Status:** ACCEPTED.

## ADR-011 Stdout contract (replaces D1 and D4)

- **Decision (PROPOSED):** every script emits exactly one status line:
  `<STATUS_TOKEN> | <human-readable message>`, where the token comes from
  `contract/stdout.json`. The token is stable and English-only, so triage can
  bucket results without parsing prose.
- **D1 (staged update):** token `STAGED`, message `<App> update staged. Waiting for app restart`, exit 0.
- **D4 (failure wording):** the ungrammatical `was not successfully update to` was kept
  only for existing reports. There are none, so the failure message becomes
  `<App> update to <version> failed: <reason>`.
- **Output limit (verified):** 2,048 characters maximum. Source: deploy-remediations.md
  (commit 4b5429d), "Script requirements". The linter will enforce a lower budget.
- **Status:** PROPOSED.

## ADR-012 D2, D3, D5 defaults

- **D2 (scope):** machine scope only; user-scope-only installs report
  `SKIPPED_USER_SCOPE`, exit 0. HKU reads see loaded hives (signed-in users) only;
  offline profiles are covered by the `C:\Users\*` path scan. `NTUSER.DAT` hives are
  not loaded. DEFAULT.
- **D3 (logs):** `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneRem_<pkg>_<detect|remediate>_<timestamp>.log`,
  prefix-scoped pruning. Inclusion in Collect diagnostics is **UNVERIFIED** (lab test). DEFAULT.
- **D5 (signing):** unsigned for v1. When signing is enabled later, scripts must be
  UTF-8 **without** BOM and run under the device execution policy; unsigned scripts run
  with `Bypass`. Source: deploy-remediations.md (commit 4b5429d), lines 68-74. DEFAULT.

## ADR-013 Encoding

- **Fact:** the docs require scripts to be UTF-8 (no BOM when signature check is on).
  Source: deploy-remediations.md lines 68-69, 135.
- **Decision:** all scripts are ASCII-only, which is byte-identical in UTF-8 (no BOM)
  and Windows-1252. The original plan's "save as Windows-1252 to mimic Intune" is
  replaced by "save as UTF-8 without BOM", per the docs.
- **Status:** PROPOSED.

## ADR-014 Time budget

- **Decision:** a 540 s static design ceiling per script (sum of declared timeout
  constants), checked by the linter.
- **UNVERIFIED:** the platform execution timeout for Remediations. It is not stated in
  the Remediations docs (searched memdocs at commit 4b5429d). It is measured in the
  lab before the ceiling is finalised.
- **Status:** DEFAULT.

## Open

- **D6:** hypervisor, Mac chip (Apple silicon vs Intel), VM access method, snapshot
  revert command, Windows edition/build/UI language. Needed before Phase 3.
- **Network allowlist:** whether to add `learn.microsoft.com` and
  `www.powershellgallery.com` to the build environment. Without PSGallery,
  PSScriptAnalyzer can only run on the Mac.
- **Licensing (verified, for the lab):** Remediations need Windows Enterprise E3/E5
  (or other listed licenses) for device users. Source: deploy-remediations.md line 49-51.
