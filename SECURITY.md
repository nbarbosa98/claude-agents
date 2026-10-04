# Security

This repository is a public Claude Code plugin marketplace. Everything merged to the default branch is delivered to every machine that runs `/plugin marketplace update claude-agents`, and it runs there with that user's permissions and credentials. Treat a change to this repository the way you would treat a change to a package you publish to npm or PyPI.

This file has three audiences:

- **People who find a vulnerability**: see [Reporting a vulnerability](#reporting-a-vulnerability).
- **People who install these plugins**: see [Using these plugins safely](#6-using-these-plugins-safely).
- **The maintainer (and contributors)**: everything else: repository settings, rules for each component type, the review checklist, and incident response.

---

## Contents

- [Reporting a vulnerability](#reporting-a-vulnerability)
- [Threat model](#threat-model)
- [1. Repository settings](#1-repository-settings)
- [2. Secrets and sensitive data](#2-secrets-and-sensitive-data)
- [3. Rules per component type](#3-rules-per-component-type)
- [4. Supply chain](#4-supply-chain)
- [5. Change process and review checklist](#5-change-process-and-review-checklist)
- [6. Using these plugins safely](#6-using-these-plugins-safely)
- [7. Incident response](#7-incident-response)
- [Current status](#current-status)

---

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting instead: **Security** tab → **Report a vulnerability**. Include the plugin name and version, what an attacker can make it do, and the steps or prompt that reproduce it.

In scope:

- A plugin doing something its README says it will not do (for example sending mail without approval, deleting permanently, running shell commands).
- Prompt-injection paths where untrusted content (an email, a web page, a file, an MCP tool result) makes an agent or skill take an action the user did not ask for.
- Secrets, credentials, tenant identifiers or personal data committed to the repository or its history.
- Hooks, scripts or MCP server configurations that can be abused to run code, escalate privileges or exfiltrate data.

Out of scope: bugs in Claude Code itself or in third-party connectors (report those to their owners), and heuristic misses that the plugin documents as known limitations (for example a phishing email not being flagged).

Only the latest version of each plugin, as published on the default branch, receives fixes.

---

## Threat model

A plugin is code and instructions that run inside the user's Claude Code session. What each component can do:

| Component | Folder | What it can do on the user's machine | Main risk |
| --- | --- | --- | --- |
| Subagent | `agent/<name>/agents/` | Uses every tool its `tools` field grants, with the user's credentials for every connected MCP server | Over-broad tool grants; acting on instructions hidden in data it reads |
| Skill | `*/skills/<name>/` | Adds instructions to the conversation; `allowed-tools` pre-approves tools; bundled scripts can be executed | Instructions that widen what Claude does; scripts that fetch and run remote code |
| MCP server | `mcp/<name>/.mcp.json` | **Starts a process** (or connects to a remote server) whenever the plugin is enabled, with the environment variables it is given | Unpinned packages, secrets in config, malicious tool descriptions |
| Hook | `*/hooks/hooks.json` | **Runs shell commands automatically** on session and tool events, without a permission prompt | Arbitrary code execution on every event |
| Slash command | `*/commands/` | Same as a skill | Same as a skill |

The attacker positions this repository must defend against:

1. **Someone who controls content the plugin reads**: an email, a web page, a document, an issue, an MCP tool result. This is the most common attack (prompt injection). Every plugin must treat that content as data, never as instructions.
2. **Someone who gets a change merged**: a malicious pull request, a compromised maintainer account or token, or a compromised dependency or GitHub Action. Because plugins update from the default branch, one bad merge reaches every user.
3. **Someone reading the public repository**: anything committed, including in old commits, closed PRs and forks, is public permanently.

---

## 1. Repository settings

Apply these in **Settings** on GitHub. The [Current status](#current-status) table records which ones were in place at the last review.

### Account

- [ ] Two-factor authentication on the owner account, with a passkey or security key rather than SMS.
- [ ] Personal access tokens are fine-grained, scoped to this repository only, and have an expiry date. Revoke tokens that are no longer used (**Settings → Developer settings**, and **Settings → Applications** for OAuth apps such as the GitHub CLI or Claude Code integrations).
- [ ] Review the account security log (**Settings → Security log**) after any suspicious event.

### Branches

- [ ] **Default branch named `main`.** It is the published channel: `/plugin marketplace add nbarbosa98/claude-plugins` reads whatever the default branch contains. Rename it in **Settings → General → Default branch**; GitHub redirects the old name.
- [ ] **A ruleset on the default branch** (**Settings → Rules → Rulesets**) that:
  - requires a pull request before merging (a solo maintainer can set required approvals to 0 and still get a reviewable diff for every change);
  - requires the validation workflow to pass (see [section 5](#5-change-process-and-review-checklist));
  - blocks force pushes and branch deletion;
  - requires linear history (optional, keeps the published history easy to audit);
  - requires signed commits (optional; see below).
- [ ] **Automatically delete head branches** after merge (**Settings → General**), and delete stale working branches such as `claude/*` once merged or abandoned.
- [ ] **Signed commits and tags** (SSH or GPG signing, or GitHub's web-flow signature for commits made through the API). Tag every release (`email-orchestrator-v0.3.1`) so users can pin to it.

### Code security (Settings → Code security)

- [ ] **Private vulnerability reporting**: on. The [Reporting](#reporting-a-vulnerability) section depends on it.
- [ ] **Secret scanning**: on.
- [ ] **Push protection**: on. It blocks pushes that contain a recognised secret.
- [ ] **Non-provider patterns** and **validity checks**: on. They catch generic secrets (private keys, connection strings, passwords in URLs) and tell you whether a leaked token still works.
- [ ] **Dependabot alerts** and **Dependabot security updates**: on, plus a `.github/dependabot.yml` for the `github-actions` ecosystem and for any `requirements.txt` / `package.json` a plugin ships.
- [ ] **Code scanning (CodeQL)**: on once the repository contains Python, JavaScript or PowerShell tooling.

### GitHub Actions (Settings → Actions → General)

- [ ] **Allowed actions**: "Allow nbarbosa98, and select non-nbarbosa98, actions and reusable workflows" with only GitHub-owned and explicitly listed actions, instead of "Allow all actions".
- [ ] **Require actions to be pinned to a full-length commit SHA.**
- [ ] **Workflow permissions**: "Read repository contents" (read-only `GITHUB_TOKEN`), and "Allow GitHub Actions to create and approve pull requests" **off**.
- [ ] **Fork pull request workflows**: require approval for all outside collaborators.
- [ ] Never use `pull_request_target` with a checkout of the PR's code, and never pass secrets to workflows triggered by forks.
- [ ] Set `permissions:` explicitly at the top of every workflow, starting from `contents: read`.

### General

- [ ] A **LICENSE** file. Without one, nobody may legally reuse the plugins, and a reused copy is harder to take down if it turns out to be vulnerable.
- [ ] Disable features you do not use (**Wiki**, **Projects**, **Discussions**) to reduce the surfaces that can hold unreviewed content.
- [ ] Optional: a `.github/CODEOWNERS` that assigns every path to the owner, so any future collaborator's change requires your review.

---

## 2. Secrets and sensitive data

Nothing below may be committed, in any file, in any branch, at any point in history:

- API keys, tokens, client secrets, passwords, certificates and private keys (`*.pfx`, `*.pem`, `*.key`).
- Tenant IDs, subscription IDs, client (app) IDs of real app registrations, internal hostnames, IP addresses, VM names, and internal URLs.
- Real email addresses, names, or message contents from a real mailbox, and any customer or employer data. Eval transcripts and test results must be sanitised before they are committed.
- Anything copied from an employer's systems. Keep work-related plugins generic, and describe environments with placeholders.

How to keep it that way:

- Every plugin that needs configuration ships an **example file with placeholders** (`00000000-0000-0000-0000-000000000000`, `<TENANT_NAME>`) and a `.gitignore` entry for the real file (for example `config/local.json`). `agent/intune-rmd-scr-agent/` already does this.
- Real values reach a plugin through **environment variables** (`${VAR}` in `.mcp.json`) or through the connector's own authentication. Never through a committed file.
- Run a secret scanner before every push, locally (`gitleaks protect --staged`) and in CI (`gitleaks detect`), in addition to GitHub push protection.
- Check for pasted identifiers before committing: `git diff --cached | grep -Ei '[0-9a-f]{8}-[0-9a-f]{4}-|onmicrosoft\.com|@[a-z0-9-]+\.(com|net|org)'`.

---

## 3. Rules per component type

### All components

- **Untrusted content is data, never instructions.** Anything read from email, web pages, files, tickets, or MCP tool results can contain an attack. Each agent and skill states this in its instructions, and treats an attempt to instruct it as a warning sign to report.
- **Least privilege.** Grant the fewest tools, scopes and permissions that complete the job. Read-only work gets read-only tools.
- **Human approval before anything outward-facing or hard to reverse**: sending, publishing, deleting, deploying, changing permissions or settings. The approval covers the exact final action; a changed action needs a new approval. Prompt-level rules are a mitigation, not a control. Where Claude Code can enforce the gate (permission `ask` / `deny` rules), document the rule in the plugin README.
- **No unattended writes.** Scheduled or looped runs are read-only unless the README states otherwise and explains why.
- **No hidden text.** Instruction files must be plain, readable text: no zero-width or bidirectional Unicode characters, no HTML comments carrying instructions, no base64 blobs. CI checks for these (see [section 5](#5-change-process-and-review-checklist)).
- **Document the safety model.** Each plugin README has a table of risks, the control for each, and whether the control is enforced by Claude Code or only by the prompt, plus known limitations.
- **Paths through `${CLAUDE_PLUGIN_ROOT}`.** Never hard-code absolute paths, home directories or usernames.

### `agent/` — subagents

- Set `tools` explicitly. Omitting it inherits **every** tool, including every connected MCP server.
- Avoid `mcp__*` wildcards. If an agent must discover providers at run time (as `email-orchestrator` does), say so in the README, use `disallowedTools` for the tools it must never touch (`Bash`, `WebFetch`, browser and computer-use servers), and give users the `ask` / `deny` rules that enforce the gate.
- Do not grant `Bash`, `Write` or `Edit` unless the job requires them, and say why in the README.
- Do not set `permissionMode`, and never suggest `bypassPermissions` in docs or examples.
- Store only settings in agent memory (`memory:`), never message bodies, codes, credentials or personal data. Document how to reset it.
- Include explicit stop conditions: when the agent must hand back to the user instead of acting.

### `skill/` — skills

- A skill's `description` decides when it loads. Keep it specific, so it does not trigger on unrelated requests and pull its instructions into them.
- Keep `allowed-tools` narrow. It pre-approves tools without a prompt while the skill is active.
- Bundled scripts must be committed in full and reviewable. **Never** download and execute code at run time (`curl … | sh`, `iex (irm …)`, `pip install` of an unpinned package), and never load instructions from a URL: a mutable remote file bypasses review.
- A skill that belongs to an agent reads that agent's security rules first (as the `email-orchestrator` skills do) so running it directly does not skip them.

### `mcp/` — MCP servers

- `.mcp.json` **starts a process** whenever the plugin is enabled. Review it like an install script.
- **Pin every server to an exact version**: `npx -y package@1.4.2`, `uvx package==1.4.2`, container images by digest (`image@sha256:…`). Never `@latest`, never an unpinned `git+https` URL.
- **No secrets in the file.** Use `${ENV_VAR}` expansion and document which variables the user must set.
- Prefer **remote servers with OAuth** or connectors that keep authentication outside the plugin. For remote servers, `https://` only, and only hosts the README names.
- Request the **smallest OAuth scopes or API permissions**, and prefer a read-only mode when the server offers one.
- List every tool the server exposes in the README, marked read or write, with the `ask` / `deny` rules that gate the write tools.
- Tool names and descriptions are read by the model: a third-party server can hide instructions in them ("tool poisoning"). Only package servers whose source you have reviewed, and re-review on every version bump.
- If you write your own server: validate every input, never build shell commands from tool arguments, restrict file access to an allowlisted directory, and time out network calls.

### `hook/` — hooks (and `hooks/hooks.json` in any plugin)

- Hooks run shell commands **automatically, without a permission prompt**, on every matching event. Keep them short, commit the full script next to `hooks.json`, and reference it through `${CLAUDE_PLUGIN_ROOT}`.
- Quote every variable; read the event JSON from stdin with a real parser (`jq`, Python), never with `eval`.
- No network access from hooks unless that is the hook's documented purpose.
- Guard hooks (hooks that block dangerous actions) **fail closed**: if the check errors, block and explain.
- A hook must not modify permissions, settings, or other plugins.

### Projects that are not plugins

A folder that is opened as its own Claude Code project (for example `agent/intune-rmd-scr-agent/`, which carries `.claude/settings.json` permission rules that a plugin cannot) follows the same rules, plus:

- Its `.claude/settings.json` is reviewed like code: `allow` rules are as narrow as possible, and `ask` / `deny` rules protect every deploy, write or tenant-changing action.
- It must refuse to run against anything but the intended environment (for example a tenant allowlist enforced by a hook), and that allowlist lives in a git-ignored local file.

---

## 4. Supply chain

- **Plugins from other repositories** (`github`, `git-subdir`, `url` sources in `marketplace.json`) are pinned with a full 40-character `sha`, and reviewed at that commit before the entry is added or the pin is moved:
  ```json
  {
    "name": "third-party-plugin",
    "source": {
      "source": "github",
      "repo": "someone/their-plugin",
      "ref": "v1.2.0",
      "sha": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    }
  }
  ```
  An unpinned external source lets its owner change what your users run without a change in this repository.
- **Do not copy third-party plugins, skills or servers in** without checking their licence, reviewing every file, and recording the origin (URL and commit) in the plugin README.
- **Dependencies** of bundled tooling (`requirements.txt`, `package.json`) are pinned to exact versions, with a lockfile where the ecosystem has one, and are covered by Dependabot.
- **GitHub Actions** are pinned to a full commit SHA with the version in a comment (`actions/checkout@<sha> # v4.2.2`), and updated through Dependabot.
- **Releases**: bump `version` in `plugin.json` for every behaviour change (users only get updates when it changes), record it in the plugin's changelog, and tag the commit.

---

## 5. Change process and review checklist

Every change reaches the default branch through a pull request, including the maintainer's own changes and changes made by Claude Code sessions.

### Automated checks (CI)

Add a workflow that runs on every pull request, with `permissions: contents: read`:

1. `claude plugin validate .` — marketplace and every plugin manifest.
2. Folder, entry and manifest names agree: `<type>/<name>/` ↔ `marketplace.json` entry `name` ↔ `plugin.json` `name`.
3. `gitleaks detect --redact` — secrets anywhere in the diff and history.
4. A search for hidden characters in instruction files: zero-width (`U+200B`–`U+200D`, `U+2060`, `U+FEFF`) and bidirectional controls (`U+202A`–`U+202E`, `U+2066`–`U+2069`).
5. `.mcp.json` check: no `@latest`, no unpinned package, no literal values in `env` except `${VAR}` references.
6. `shellcheck` for shell scripts, `PSScriptAnalyzer` for PowerShell, and the linter/tests of any plugin that ships tooling.

### Pull request checklist

Copy into the PR description:

```markdown
- [ ] No secrets, tenant/app IDs, internal hosts, real addresses or personal data (diff and new files)
- [ ] New or changed tools/scopes/permissions are the minimum needed and are listed in the README
- [ ] Untrusted-content rule present in every new agent and skill
- [ ] Outward-facing or destructive actions need explicit user approval; enforcing `ask`/`deny` rules documented
- [ ] No `curl | sh`, remote instructions, unpinned packages or `@latest`
- [ ] Hooks: full script committed, variables quoted, fails closed, no network
- [ ] External plugin sources pinned by `sha` and reviewed at that commit
- [ ] Plugin README safety model and known limitations updated
- [ ] `version` bumped in plugin.json and changelog entry added
- [ ] Evals re-run for safety-relevant changes (injection, approval gates) and results sanitised
```

### Reviewing changes written by an AI agent

Many changes here are written by Claude Code sessions. Review them with the same checklist, and look specifically for: broadened `tools` lists or permission rules, new network calls, weakened tests or linter rules, and instructions that soften an existing safety rule.

---

## 6. Using these plugins safely

For anyone who installs from this marketplace:

- **Read the plugin's README before installing**, especially its safety model and the tools it uses. Look at `.mcp.json` and `hooks/` in the plugin folder if they exist: those run code on your machine.
- **Pin a version** when you need stability or run in a sensitive environment:
  ```text
  /plugin marketplace add nbarbosa98/claude-plugins@<tag-or-commit>
  ```
  Otherwise you receive whatever is merged to the default branch at your next update. Review the diff before updating.
- **Enforce approval gates yourself** with permission rules in `~/.claude/settings.json`. `ask` and `deny` rules are checked before `allow` rules, so a plugin cannot skip them. For example, to require a prompt before any email is sent:
  ```json
  {
    "permissions": {
      "ask": ["mcp__*__send*", "mcp__*__reply*", "mcp__*__forward*"]
    }
  }
  ```
- **Do not use `bypassPermissions` mode** with plugins that can write, send or deploy.
- Install only the plugins you need, and uninstall the ones you stop using: `/plugin uninstall <name>@claude-agents`.
- **Organisations** can restrict which marketplaces users may add with `strictKnownMarketplaces` in managed settings, pinning this repository to a reviewed `ref`.

---

## 7. Incident response

### A secret was committed

1. **Revoke or rotate it first**, at the provider. Assume it is already compromised: public repositories are scraped within minutes, and forks and caches keep copies.
2. Check the provider's logs for use of the secret since the commit.
3. Remove it from history with `git filter-repo`, force-push every affected branch, and delete stale branches and tags that still contain it. Ask GitHub Support to purge cached views and pull request refs if needed.
4. Add a pattern (or `.gitignore` entry) that stops it happening again.

### A plugin behaved unsafely or was tampered with

1. Revert the change on the default branch, bump the plugin's patch version so installed copies update, and tag the fix.
2. If users may have been affected, publish a **GitHub Security Advisory** for the repository describing the affected versions and what to do (uninstall, update, rotate credentials the plugin had access to).
3. Record the failure mode in the plugin's README and add an eval case that reproduces it.

### The account or a token was compromised

1. Change the password, revoke all sessions, personal access tokens, SSH keys, deploy keys and OAuth app authorisations, and re-enrol 2FA.
2. Review the security log and the repository's recent commits, branches, tags, webhooks, Actions secrets and collaborators for anything you did not add.
3. Compare the default branch with the last commit you trust, revert anything unexplained, and follow the plugin steps above.

---

## Current status

Findings from the review on **2026-09-28**. Update this table when a setting changes.

| Item | Status |
| --- | --- |
| Default branch | ⚠️ `claude/admiring-brown-4s7g6u`, not `main`. Rename it; it is the published channel. |
| Branch protection / rulesets | ❌ None. Anyone with push access (or a leaked token) can push directly to the published channel. |
| Secret scanning | ✅ On |
| Push protection | ✅ On |
| Non-provider patterns, validity checks | ❌ Off |
| Private vulnerability reporting | ❌ Off. Required by [Reporting a vulnerability](#reporting-a-vulnerability). |
| Dependabot alerts / security updates | ❌ Off |
| Actions: allowed actions | ⚠️ All actions allowed; SHA pinning not required |
| Actions: default `GITHUB_TOKEN` permissions | ✅ Read-only; Actions cannot approve PRs |
| CI validation workflow | ❌ None yet |
| LICENSE | ❌ Missing (all rights reserved) |
| Release tags | ❌ None |
| Stale branches | ⚠️ `claude/keen-bohr-g0d8iv` (merged); `claude/upbeat-meitner-kwq2fq` (holds unmerged intune Phase 1–2 work) |
| Owner 2FA | ❓ Not verifiable with the token used for the review; check in account settings |
| Committed secrets or identifiers | ✅ None found in the current tree; examples use placeholders and `config/local.json` is git-ignored |
| `email-orchestrator` tool scope | ⚠️ Uses `mcp__*` by design (provider discovery). Mitigated by `disallowedTools` and documented `ask` rules; the send gate is prompt-level unless the user adds those rules. |
