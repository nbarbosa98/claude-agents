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
- **Status:** ACCEPTED (ADR-015).

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
- **Status:** ACCEPTED (ADR-015).

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
- **Status:** ACCEPTED (ADR-015).

## ADR-014 Time budget

- **Decision:** a 540 s static design ceiling per script (sum of declared timeout
  constants), checked by the linter.
- **UNVERIFIED:** the platform execution timeout for Remediations. It is not stated in
  the Remediations docs (searched memdocs at commit 4b5429d). It is measured in the
  lab before the ceiling is finalised.
- **Status:** DEFAULT.

## ADR-015 Script types accepted

- **Decision:** `docs/script-types.md` accepted by the owner. Section 6 questions take the
  proposed defaults: status line `<TOKEN> | <message>`; fail-safe `NOT_DETERMINED` exit 0
  when state is unknown (all types, including vuln); audit exits 1 on a finding; the
  config-change guardrail list as drafted; no extra types.
- ADR-004 (routing), ADR-011 (contract) and ADR-013 (encoding) move to ACCEPTED with it.
- **Status:** ACCEPTED.

## ADR-016 winget under SYSTEM is unsupported (re-opens Pattern A)

- **Fact:** "the WinGet CLI is not supported in the system context. The
  Microsoft.WinGet.Client PowerShell module can be used in the system context with
  applications that are installed machine wide." Source:
  https://raw.githubusercontent.com/MicrosoftDocs/windows-dev-docs/docs/hub/package-manager/winget/troubleshooting.md
  (section "System Context").
- **Fact:** `Microsoft.WinGet.Client` declares `CompatiblePSEditions = Desktop, Core` and
  `PowerShellVersion = 5.1.0`, so it can load in Windows PowerShell 5.1. It exposes
  `Get-WinGetPackage` (objects with `IsUpdateAvailable`), `Update-WinGetPackage`
  (`-Mode Silent`, `-Scope`, `-IncludeUnknown`, `-MatchOption`) and
  `Repair-WinGetPackageManager` (`-AllUsers`, `-Latest`). Sources:
  microsoft/winget-cli `src/PowerShell/Microsoft.WinGet.Client/ModuleFiles/Microsoft.WinGet.Client.psd1`
  and `src/PowerShell/Help/Microsoft.WinGet.Client/*.md` (master, fetched 2026-09-27).
- **Options:**
  - (a) `Microsoft.WinGet.Client` module, pre-installed on devices by a separate
    prerequisite package (AllUsers module path, pinned version). If it is missing,
    detection reports `NOT_DETERMINED`, exit 0. The supported path. Object output also
    removes the locale problem of parsing `winget` text.
  - (b) Call `winget.exe` from its `WindowsApps` folder. Widely used, but explicitly
    unsupported by Microsoft.
  - (c) Skip winget and use vendor-direct installs (Pattern B1) for every app. More
    per-app work and no catalog.
- **Recommendation:** (a). UNVERIFIED until the lab: behaviour under SYSTEM with 64-bit
  Windows PowerShell 5.1, the module's App Installer dependency, and run time.
- **Decision (owner, Phase 1):** option (b), call `winget.exe` directly.
- **Consequences:** Pattern A runs on a path Microsoft documents as unsupported. Mitigations:
  every winget failure maps to `NOT_DETERMINED` (detect) or `FAILED` (remediate), never to a
  false success; currency is decided by version comparison, not winget text; the path is
  located by `Get-WingetPath` only. Listed in `docs/limitations.md` (Phase 9) and
  `references/failure-modes.md` FM-01/FM-02. Revisit if lab results are poor.
- **Status:** ACCEPTED.

## ADR-017 Lab VM topology

- **Decision (PROPOSED):** two roles, never mixed.
  - **Gate 4 VM:** x64 Windows 11 Enterprise, not Intune-enrolled, reverted to a
    `baseline` snapshot before each run.
  - **Pilot device(s):** Entra-joined, Intune-enrolled, never reverted. Used for the
    Phase 5 pilot ring.
- **Why separate (inference):** reverting a snapshot rolls back enrollment and
  certificate state, which can leave the device inconsistent with Intune. An enrolled VM
  would also receive real policies during tests, which contaminates Gate 4 results.
- **Why x64:** on Apple-silicon Macs, local hypervisors run Windows 11 on ARM64. There,
  installer selection and emulation differ from an x64 fleet.
- **Backend (owner, Phase 3):** Azure. The owner's Mac is Apple silicon (local VMs would be
  ARM64) and the owner has an Azure subscription. The Gate 4 VM is an x64 Windows 11
  Enterprise VM in Azure; the owner creates it later (tools/vm/README.md).
- **Status:** ACCEPTED.

## ADR-018 Temp files for captured process output

- **Decision:** `Invoke-ProcessWithTimeout` writes stdout/stderr capture files with
  `[System.IO.Path]::GetTempFileName()` (under SYSTEM: `C:\Windows\Temp`). They are only
  read, never executed, and deleted in `finally`. Anything executed goes through secure
  staging (HR-07).
- **Status:** ACCEPTED (carried over from the original spec's F3).

## ADR-019 Catalog version source for Pattern A

- **Decision:** `winget show --id <id> --exact --source winget --versions` and take the
  highest line that is a bare version. Header lines are localised but never parse as a
  version, so the result does not depend on the UI language.
- **Alternatives:** parsing labelled `winget show` fields (locale-dependent);
  `winget list` table parsing (column truncation risk); `Microsoft.WinGet.Client`
  (rejected with ADR-016).
- **Source:** `--versions` option, MicrosoftDocs/windows-dev-docs
  `hub/package-manager/winget/show.md`.
- **UNVERIFIED:** output shape under SYSTEM and in a non-English image. Phase 3.
- **Status:** ACCEPTED (owner, after Phase 1). Lab evidence in Phase 3 can re-open it.

## ADR-020 Safety layers built in Phase 1

1. **Permissions** (`.claude/settings.json`): `ask` on `tools/graph/write/*` and on edits to
   `contract/`, `tools/lint/`, `evals/fixtures.json`, `.claude/hooks/`, `.claude/settings.json`;
   `deny` on reading `config/local.json`, on encoded PowerShell commands, and on raw
   curl/wget to Graph; `disableBypassPermissionsMode: disable`, because bypass mode skips
   `ask` prompts.
2. **tenant-guard hook** (all Bash): Graph writes only through `tools/graph/write/` with an
   allowlisted `-TenantId`; fails closed without a valid `config/local.json`.
3. **readonly-guard hook** (subagent-scoped, ops-agent and classifier): Bash limited to
   single commands running their own read-only tool scripts.
4. **Tool budgets**: generators have no Bash, no network and no Agent tool; the reviewer is
   Read/Grep/Glob only.
5. **Plan-hash approval and in-tool tenant check** (`tid` claim): Phase 5.
- **Limit (fact):** "a deny or ask rule covers the invocation Claude usually produces and
  isn't a security boundary" (https://code.claude.com/docs/en/permissions). Hooks match
  command text the same way. That is why layer 5 re-checks the tenant inside the tool.
- **Status:** ACCEPTED (implemented; owner review in the Phase 1 report).

## ADR-021 Slash commands as skills

- **Decision:** `/new-remediation`, `/deploy`, `/promote`, `/ops`, `/drift`, `/eval` are
  skills in `.claude/skills/<name>/SKILL.md`, not `.claude/commands/`. `/triage` is renamed
  `/ops` (ADR-003, N2).
- **Why:** commands were merged into skills; `.claude/commands/` still works, but skills
  support `disable-model-invocation: true`, which stops Claude from starting `/deploy` or
  `/promote` by itself. Source: https://code.claude.com/docs/en/skills.
- **Status:** ACCEPTED.

## ADR-022 Template placeholders

- **Decision:** templates use `__NAME__` placeholders instead of `[NAME]`, because
  `[UPPER]` collides with PowerShell type literals and attribute syntax. Gate 1 checks the
  pattern `__[A-Z][A-Z0-9_]*__` (plus `<AppDisplayName>`).
- **Status:** ACCEPTED.

## ADR-023 Contract v1.0.0 details

- 19 tokens across 5 types. Details in `contract/stdout.json` and the generated
  `references/contract.md`.
- `ERROR` (unhandled exception) exits 0 in detection and 1 in remediation, following the
  fail-safe default (ADR-015).
- `PENDING_REBOOT` is allowed for app-update, because winget can return
  "Restart your PC to finish installation" (0x8A150109).
- The remediation script may emit the compliant token (`UP_TO_DATE`, `COMPLIANT`,
  `NOT_EXPOSED`) when its re-check finds nothing to do (HR-19).
- **Status:** ACCEPTED (owner, after Phase 1). Further contract changes need owner approval.

## ADR-024 Models

- **Decision:** every agent uses `model: inherit` for now. Right-sizing (for example a
  smaller model for classifier or ops-agent) waits for eval data (Phase 8).
- **Status:** DEFAULT.

## ADR-025 winget-pkgs access through a partial git clone

- **Decision:** `tools/classify/winget_manifest_lookup.py` reads
  https://github.com/microsoft/winget-pkgs through a shallow, tree-less partial clone
  (`git clone --depth 1 --filter=tree:0 --no-checkout`) cached in `out/cache/winget-pkgs`.
  Git fetches only the trees and blobs of the package being looked up.
- **Why not the GitHub API (original spec):** the API is blocked for this repository in the
  build environment; unauthenticated API use is rate-limited to 60 requests per hour; the
  git route reads the same source with no token.
- **Verified facts:**
  - Manifest path layout: `manifests/<lowercase first character>/<identifier with '.' as '/'>/<version>/<identifier>.installer.yaml`.
    Source: winget-pkgs `doc/manifest/schema/1.12.0/installer.md` (example
    `manifests/m/Microsoft/WindowsTerminal/1.9.1942/...`). Multi-dot identifiers are nested
    folders, observed live: `manifests/m/Microsoft/VisualStudio/2022/Community`.
  - Field names `Installers[].Architecture`, `InstallerType`, `NestedInstallerType`, `Scope`,
    `InstallerSha256`, `InstallerUrl`; `InstallerType`, `NestedInstallerType` and `Scope` may
    also be set at the manifest root. Source: same file, schema 1.12.0 (latest found;
    1.11.0 does not exist in the repo).
- **Approximation:** latest version = highest by numeric-first ordering; non-numeric
  versions produce a warning.
- **Status:** ACCEPTED (owner, 2026-10-02).

## ADR-026 Gate 1 design

- **Decision:** Python rule engine (`tools/lint/lint.py`) over PowerShell AST facts
  (`tools/lint/Get-ScriptFacts.ps1`, never executes the script). Runs wherever `pwsh` and
  Python run (macOS, Linux, Windows). PSScriptAnalyzer is merged in when installed;
  without it the status is `PASS_PENDING_PSSA`, which is not deliverable.
- **Budget:** the original spec summed the declared constants. Gate 1 instead sums the
  timeout argument at each call site, plus 15 s per process-running helper (the
  `taskkill` wait inside `Invoke-ProcessWithTimeout`), because a constant used twice waits
  twice. Calls inside loops are flagged for the reviewer.
- **Canonical helpers** are compared byte for byte; rules that inspect command
  parameters skip their bodies (they can use splatting, and are reviewed at the source).
- **Rule catalog:** `tools/lint/README.md`; each rule has a mutation test.
- **PSScriptAnalyzer settings:** `PSUseCompatibleSyntax` (5.1) and `PSUseCompatibleCommands`
  (profile `win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`);
  `PSAvoidUsingWriteHost` excluded (Write-Host is the deliberate status channel). Source:
  MicrosoftDocs/PowerShell-Docs-Modules `reference/docs-conceptual/PSScriptAnalyzer/Rules/`.
  Not yet run: PowerShell Gallery is blocked in the build environment.
- **Status:** ACCEPTED (owner, 2026-10-02).

## ADR-027 Gate 2 design

- **Decision:** one generic Pester 5 test file driven by per-type/pattern scenario
  matrices (`tools/pester/matrices/`), with shared mocks. Scripts are parsed, not run as
  files; the main block runs with side-effecting helpers mocked.
- **Coverage:** every token a script can emit, plus `ERROR`, must have a scenario;
  otherwise Gate 2 fails. This is the mechanical form of "cover every exit path".
- **Cross-platform:** scenarios that need Windows cmdlet behaviour are marked
  `WindowsOnly`, skipped elsewhere, and reported as `PASS_PENDING_WINDOWS` (not
  deliverable); they run in the Gate 4 VM. Off Windows the harness simulates the
  environment variables and a `C:` drive for path building only.
- **Matrices are tests:** they are added to the `ask` list in `.claude/settings.json`, so
  edits need the owner's approval (rule: never weaken a test).
- **Status:** ACCEPTED (owner, 2026-10-02).

## ADR-028 Defects found and fixed by the Phase 2 tests

1. `return , $array` in `Get-MachineInstalls` / `Get-UserScopeInstalls`, combined with `@()`
   at the call site, produced a one-element array even when nothing was found, so
   "not installed" could never be detected. Fixed: helpers emit items; callers use `@()`.
   Classification: root-cause fix.
2. `ValidatePattern` is case-insensitive, so `Exit-WithCode` accepted lowercase tokens.
   Fixed with `ValidateScript({ $_ -cmatch ... })`. Classification: root-cause fix
   (defence in depth; Gate 1 already required contract literals).
3. The installed-version routine was duplicated text in two scripts. It is now the canonical
   helper `Get-InstalledAppVersion`, so detection and remediation cannot diverge (FM-13).
   Classification: best practice.
4. winget exit-code constants moved from the helper library to the package constants block,
   so the helper section contains only functions. Classification: cosmetic.
- **Status:** ACCEPTED (defect fixes; reported in the Phase 2 report).

## ADR-029 Gate 4 design

- **Transport:** Azure Run Command (`RunPowerShellScript`), driven by the Azure CLI from the
  operator's Mac. Verified: runs as System, one script at a time, at most 90 minutes, output
  limited to the last 4,096 bytes (MicrosoftDocs/azure-compute-docs
  `articles/virtual-machines/windows/run-command.md`). Hence a small guest agent
  (`GateGuest.ps1`) that returns base64 JSON in chunks, and chunked uploads of a zipped
  payload (parameter size limits are not documented: UNVERIFIED).
- **Execution fidelity:** each script runs from a one-shot scheduled task as SYSTEM in 64-bit
  `powershell.exe -ExecutionPolicy Bypass -File` (Bypass verified for unsigned Remediations),
  with a hard kill at 600 s. Identity, bitness and PowerShell version are recorded and
  asserted for every run.
- **Revert:** snapshot -> new managed disk -> `az vm stop` -> `az vm update --os-disk` ->
  `az vm start` -> wait for the VM agent. Verified in the same docs repo
  (`linux/os-disk-swap.md`, `scripts/create-managed-disk-from-snapshot.md`). Only disks the
  harness created (tag `intune-rmd-gate4=temp`) are deleted.
- **Safety:** the Azure backend refuses to run unless the signed-in subscription equals
  `config/local.json` `vm.azure.subscriptionId`; results never contain subscription,
  resource or tenant IDs.
- **Tampered installer** without a test hook in production code: the host stages a copy of
  `remediate.ps1` with `$EXPECTED_SIGNER_O` replaced. The real script is uploaded unchanged
  (asserted by a test).
- **Never over-report:** a scenario that cannot run (no user profile, no Pester 5) is
  `NOT_RUN` and the gate `INCOMPLETE`; a backend without revert (local) is `INCOMPLETE`.
- **Deviation from the original spec:** scripts are delivered as UTF-8 without BOM, not
  Windows-1252 (ADR-013; ASCII makes them byte-identical). The original "measure the platform
  timeout and IME PowerShell version" cannot be done with a scheduled task; it moves to a
  diagnostic package in the Phase 5 pilot ring.
- **Status:** ACCEPTED (owner, 2026-10-02).

## ADR-030 PSScriptAnalyzer from source; helper renames

- **PSScriptAnalyzer:** the PowerShell Gallery is blocked in the cloud build environment, so
  version 1.25.0 was built from github.com/PowerShell/PSScriptAnalyzer (commit 411c3d0) with
  NuGet packages from nuget.org (`tools/setup/install-psscriptanalyzer-from-source.sh`). On
  the Mac, `Install-Module PSScriptAnalyzer` is the normal route (PSScriptAnalyzer README).
- **Findings acted on (Gate 1 now runs with zero PSSA findings on all fixtures):**
  - `Write-Log` is a built-in cmdlet name in some PowerShell editions
    (PSAvoidOverwritingBuiltInCmdlets): renamed `Write-RemediationLog`. Best practice.
  - Plural nouns (PSUseSingularNouns): `Get-MachineInstalls` -> `Get-MachineInstall`,
    `Get-UserScopeInstalls` -> `Get-UserScopeInstall`. Cosmetic.
  - Unused constants per role (PSUseDeclaredVarsMoreThanAssignments): fixtures now declare
    role-specific constants in `<role>.constants.ps1`; Pattern A detection now actually
    implements `$INCLUDE_UNKNOWN` (unknown version treated as outdated), which it had
    declared but ignored. Root-cause fix.
  - Deliberate empty catch in the logger and no ShouldProcess in unattended SYSTEM helpers:
    suppressed per function with a written justification (`SuppressMessageAttribute`), not
    by turning the rules off.
- **Status:** ACCEPTED (defect fixes and renames; reported in the Phase 3 report).

## Open

- **D6:** resolved by ADR-017 (Azure, x64). Windows build and UI language are recorded from
  the VM by `Initialize-GateVm.ps1`; a non-English second image is still optional.
- **Network allowlist:** `learn.microsoft.com` and `www.powershellgallery.com` remain
  blocked in the build environment; worked around (docs source repos, PSScriptAnalyzer built
  from source, ADR-030).
- **Licensing (verified, for the lab):** Remediations need Windows Enterprise E3/E5
  (or other listed licenses) for device users. Source: deploy-remediations.md line 49-51.
