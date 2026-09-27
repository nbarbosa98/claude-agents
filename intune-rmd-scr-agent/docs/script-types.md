# Script types - DRAFT for owner review

Status: **ACCEPTED** (owner review, Phase 0). The open questions in section 6 were not
answered individually, so the proposed defaults apply. Pattern A's install mechanism is
re-opened by ADR-016. This document becomes `contract/stdout.json` plus one reference file per type under
`.claude/skills/intune-remediation/references/`.

Target: Windows-only fleet, Intune Remediations, run as SYSTEM, 64-bit, Windows
PowerShell 5.1 syntax (ADR-009).

## 1. Platform facts every type relies on

| Fact | Status | Source |
|---|---|---|
| Package = detection script only, or detection + remediation | Verified | memdocs `intune/device-management/tools/deploy-remediations.md` @4b5429d, l.66 |
| Remediation runs only when detection exits `1`; any other code means no remediation | Verified | same, l.67 and l.148 |
| Empty detection output results in an "issue isn't found" state | Verified | same, l.148 |
| Output limit 2,048 characters | Verified | same, l.70 |
| Scripts must be UTF-8; no BOM if signature check is enforced | Verified | same, l.68-69 |
| Unsigned scripts run with `Bypass` execution policy | Verified | same, l.74 |
| Schedules: once, hourly (every n hours, n < 24), daily at a time; local time unless "Use UTC"; missed runs execute when the device is next online | Verified | same, l.97-110 |
| Platform execution timeout | **UNVERIFIED** | not in the Remediations docs; measure in lab |
| PowerShell host version used by the IME | **UNVERIFIED** | not in the Remediations docs; measure in lab |

## 2. Routing (orchestrator)

| Request looks like | Goes to | Notes |
|---|---|---|
| "Keep <app> up to date" | `app-update-agent` | Classifier builds the evidence record first |
| "Fix CVE-xxxx / Defender recommendation for <app>" | `vuln-remediation-agent` | If the fix is an app update, it reuses the app-update blocks |
| "Fix CVE" that needs an OS cumulative update | **Refuse** | Use Windows Update for Business / Autopatch |
| Microsoft 365 Apps (Click-to-Run) version | **Refuse** | Use M365 Apps update channels |
| "Make sure setting X is Y" | `config-change-agent` | Warns first if a Settings Catalog / CSP profile can do it |
| "Tell me which devices have X" | `audit-agent` | Detection only, no changes |
| Anything else | `general-agent` | Re-routes if another type fits |
| Unclear or two types fit | **Ask the user** | Never guess |

## 3. Shared skeleton (all five types)

Every script, detection and remediation, has the same sections in this order. The
linter checks the order and presence.

```
1. Header comment      package id, type, script role (detect|remediate), contract
                       version, generator version. ASCII only.
2. Constants block     all tunables, including every timeout in seconds
                       ($TIMEOUT_*), so the linter can sum them (<= 540 s).
3. Helpers             Write-Log, Exit-WithCode (throws ExitCalled:<n> under test,
                       exits in production), Invoke-WithTimeout, plus type-specific
                       helpers. Only helpers the script uses are included.
4. Main                try { ... } catch { if ExitCalled:* rethrow; else log,
                       emit ERROR status, exit 1 }.  Raw `exit` only in the outer catch.
5. Status output       exactly ONE Write-Output line per run:
                       "<STATUS_TOKEN> | <message>"   (<= 512 chars, well under 2,048)
```

Shared rules:

- Logs: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneRem_<pkg>_<detect|remediate>_<yyyyMMdd-HHmmss>.log`;
  prune only `IntuneRem_<pkg>_*.log` older than N days.
- No user-profile environment variables (`$env:LOCALAPPDATA`, `$env:APPDATA`,
  `$env:USERPROFILE`): under SYSTEM they point at the system profile.
- Every external process has a bounded wait (`WaitForExit(<ms>)`); every web request
  has `-TimeoutSec`.
- Fail-safe default: if the script cannot determine state (e.g. network down,
  source unavailable), detection exits `0` with a `SKIPPED_*` or `NOT_DETERMINED`
  token rather than triggering a remediation it cannot complete. Choosing fail-open
  vs fail-closed is recorded per package in the decision record.

## 4. Types

### 4.1 app-update-agent - keep an app current

**Detection**
1. Find machine-scope installs: HKLM Uninstall (64- and 32-bit views), `Program Files` and
   `Program Files (x86)`. Version trust order: main exe FileVersion, then registry
   DisplayVersion.
2. If not found machine-wide, look for user-scope installs (`C:\Users\*\AppData\...`,
   loaded HKU hives). If found only there: `SKIPPED_USER_SCOPE`, exit 0 (D2).
3. Get the target version (catalog latest, or a pinned minimum from the decision record).
4. Compare with `[version]` casts. Outdated: exit 1. Current: exit 0.

**Remediation sub-patterns** (chosen by the classifier, with evidence):

| Pattern | When | Install path |
|---|---|---|
| A | App is in winget with a machine-scope installer | `winget upgrade --id <id> --exact --scope machine --silent --accept-*`, bounded |
| Browser | Chrome, Edge, Firefox: self-updating, in use while running | Vendor enterprise MSI or updater; `STAGED` when the new version waits for a restart |
| B1 | Not in winget | Vendor download URL, secure staging, trust check, silent install |
| B2 | Multiple parallel versions by design (Node.js, Python) | Update within the installed major/minor line only; never cross lines |
| B3 | Side-by-side majors (.NET runtimes) | Per-major servicing; never remove other majors |

**Guards:** secure staging dir (SYSTEM + Administrators only, deleted in `finally`);
installer trust check (Authenticode `Valid` + expected signer; SHA256 when the vendor
publishes one); post-install version check before reporting success.

**Tokens:** `NOT_INSTALLED`, `UP_TO_DATE`, `OUTDATED`, `SKIPPED_USER_SCOPE`,
`NOT_DETERMINED`, `REMEDIATED`, `STAGED`, `FAILED`, `ERROR`.

### 4.2 vuln-remediation-agent - close a named exposure

Input: a CVE ID or Defender vulnerability recommendation, plus evidence (vendor
advisory URL, affected range, fixed version or mitigation).

**Detection:** evaluates the exposure condition, not a general health check:
- version-based: installed version inside the affected range; or
- mitigation-based: required registry/feature/service state absent.
The status message names the CVE ID(s), so the Intune output column shows which
exposure a device has.

**Remediation:**
- version-based: reuses the app-update remediation block for that app (one code path).
- mitigation-based: applies the documented vendor mitigation only; records the prior
  value in the log for rollback; verifies after applying.
- Uninstalling software to close an exposure requires explicit owner confirmation at
  generation time and is flagged by the reviewer.

**Tokens:** `NOT_APPLICABLE` (software absent), `NOT_EXPOSED`, `EXPOSED`,
`MITIGATED`, `PENDING_REBOOT`, `FAILED`, `ERROR`.

### 4.3 config-change-agent - enforce a desired setting state

**Before generating:** checks whether Settings Catalog or a CSP can enforce the
setting. If yes, it recommends the profile (declarative, native reporting, no script
to maintain) and builds a script only if the owner still wants one. The reason is
recorded in the package README.

**Structure:** a declarative desired-state table in the constants block:

```
$DESIRED = @(
  @{ Kind='Registry'; Path='HKLM:\...'; Name='...'; Type='DWord'; Value=1 },
  @{ Kind='Service';  Name='...';  StartType='Disabled' }
)
```

- Detection evaluates every entry and reports the drifted ones (count + names within
  the output budget).
- Remediation changes only drifted entries, logs each prior value (rollback data),
  then re-evaluates.

**Guardrails (reviewer blocks unless the owner explicitly approves):** turning off
Defender AV, firewall, UAC, BitLocker, Windows Update, SmartScreen or LSA protection;
writes under `HKCU` or other users' hives.

**Tokens:** `COMPLIANT`, `DRIFTED`, `REMEDIATED`, `PENDING_REBOOT`, `FAILED`, `ERROR`.

### 4.4 audit-agent - report only

**Detection script only; no remediation script.**

- Collects facts and emits one compact `key=value;...` summary within the output budget.
- Exit 1 when a finding exists (so Intune counts the device as "with issues"), 0 when clean.
  Because there is no remediation script, exit 1 changes nothing on the device.
- Linter bans state-changing commands (for example `Set-*`, `New-Item` outside the log
  dir, `Remove-*`, `reg add`, `sc config`, `Stop-Service`, installers).
- Privacy: no user names, e-mail addresses or file contents in the output; counts and
  identifiers only. The output is visible to every Intune admin with read access.

**Tokens:** `AUDIT_CLEAN`, `AUDIT_FINDING`, `NOT_DETERMINED`, `ERROR`.

### 4.5 general-agent - anything else

- Must use the shared skeleton and contract. Tokens are chosen from the shared set
  (`COMPLIANT`, `NONCOMPLIANT`, `REMEDIATED`, `PENDING_REBOOT`, `FAILED`, `ERROR`,
  `NOT_APPLICABLE`); no new tokens without a contract change.
- Must document a rollback procedure in the README.
- Reviewed at the highest risk level: every reviewer `WARN` becomes blocking.
- If the request fits another type, it hands back to the orchestrator instead.

## 5. Exit-code summary

| Script | exit 0 | exit 1 |
|---|---|---|
| Detection | compliant / not applicable / skipped / staged | issue found: remediation runs (audit: finding, nothing runs) |
| Remediation | change applied and verified, or staged | failed; the device stays non-compliant and is retried at the next schedule |

## 6. Open questions for the owner

1. Status line format `<TOKEN> | <message>`: OK?
2. Fail-safe default (detection exits 0 with `NOT_DETERMINED` when state is unknown): OK,
   or do you want fail-closed (exit 1) for vuln-remediation?
3. Audit exits 1 on a finding: OK?
4. Config-change guardrail list: add or remove anything?
5. Anything missing from the types, for example local admin group membership, certificate
   checks or scheduled-task cleanup? These fit today as config-change or audit.
