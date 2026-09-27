# claude-agents

A curated collection of Claude Code agents, packaged as **plugins** and published from a single **plugin marketplace**. Add this repository to Claude Code once, then install, update, or remove any agent on demand.

The repository is also a working portfolio of applied agentic AI: each agent is scoped to a real task, has an explicit tool budget, and documents the design decisions behind it.

---

## Contents

- [Why this repo exists](#why-this-repo-exists)
- [Quick start](#quick-start)
- [Agent catalog](#agent-catalog)
- [Repository layout](#repository-layout)
- [How an agent is built](#how-an-agent-is-built)
- [Design principles](#design-principles)
- [Adding a new agent](#adding-a-new-agent)
- [Versioning and syncing](#versioning-and-syncing)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why this repo exists

| Goal | How it is achieved |
| --- | --- |
| **One source of truth** | Every agent lives here, versioned in Git, instead of being copied between machines and projects. |
| **Install on demand** | Each agent is a self-contained plugin. Install only what a project needs. |
| **Sync anywhere** | Pull the latest versions into any Claude Code environment with a single command. |
| **Show the work** | Each agent documents its purpose, tool permissions, limits, and trade-offs. |

---

## Quick start

Requires [Claude Code](https://code.claude.com/docs) with plugin support.

**1. Add the marketplace** (one time per machine):

```text
/plugin marketplace add nbarbosa98/claude-agents
```

**2. Browse and install an agent:**

```text
/plugin                                   # interactive browser
/plugin install <plugin-name>@claude-agents
```

**3. Pull the latest versions at any time:**

```text
/plugin marketplace update claude-agents
```

After installing, the agent's subagents, skills, and commands are available in Claude Code. Subagents can be invoked by name or picked automatically by Claude based on their `description`.

### Enable for a whole team or project

To make the marketplace available to everyone who works in a project, commit this to that project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "claude-agents": {
      "source": { "source": "github", "repo": "nbarbosa98/claude-agents" }
    }
  },
  "enabledPlugins": {
    "<plugin-name>@claude-agents": true
  }
}
```

---

## Agent catalog

| Plugin | What it does | Components | Status |
| --- | --- | --- | --- |
| [`email-orchestrator`](plugins/email-orchestrator) | Briefs, categorizes, tracks unanswered important emails, flags phishing, cleans up the inbox, and drafts and sends email (each after you confirm) across Gmail, Outlook, and other connected mail services | 1 subagent, 6 skills | `0.2.0` — beta |

Each plugin folder contains its own `README.md` covering usage, required tools, example prompts, and known limitations.

---

## Repository layout

```text
claude-agents/
├── .claude-plugin/
│   └── marketplace.json        # Marketplace manifest: lists every plugin in this repo
├── plugins/
│   └── <plugin-name>/
│       ├── .claude-plugin/
│       │   └── plugin.json     # Plugin metadata (name, version, description, author)
│       ├── agents/             # Subagents: Markdown files with YAML frontmatter
│       ├── skills/             # Optional: Agent Skills (<skill>/SKILL.md)
│       ├── commands/           # Optional: slash commands
│       ├── hooks/              # Optional: hooks.json for lifecycle automation
│       ├── .mcp.json           # Optional: MCP servers the plugin depends on
│       └── README.md           # Usage and design notes for this plugin
└── README.md
```

Only `plugin.json` is required per plugin. Every other folder is included when the agent needs it.

### Marketplace manifest

`.claude-plugin/marketplace.json` registers each plugin:

```json
{
  "name": "claude-agents",
  "owner": { "name": "Nelson Barbosa" },
  "plugins": [
    {
      "name": "example-agent",
      "source": "./plugins/example-agent",
      "description": "One-line summary of what the agent does."
    }
  ]
}
```

---

## How an agent is built

A subagent is a Markdown file in a plugin's `agents/` folder. The frontmatter defines **when** it runs and **what it may do**; the body is its system prompt.

```markdown
---
name: example-agent
description: Use this agent when <specific trigger>. It <specific outcome>.
tools: Read, Grep, Glob
model: sonnet
---

You are a specialist in <domain>.

## Goal
<The single outcome this agent is responsible for.>

## Process
1. <Step>
2. <Step>

## Output
<Exact format of the result returned to the caller.>

## Boundaries
- <What the agent must not do.>
- <When to stop and hand back to the user.>
```

| Field | Purpose |
| --- | --- |
| `name` | Unique identifier used to invoke the agent. |
| `description` | Routing signal. Claude uses it to decide when to delegate, so it must state the trigger clearly. |
| `tools` | Allowlist of tools. Omit to inherit all tools; restrict it wherever possible. |
| `model` | Optional model override (for example `sonnet`, `opus`, `haiku`, or `inherit`). |

---

## Design principles

These are the rules every agent in this repository follows.

1. **Single responsibility.** One agent, one clearly bounded job. Broad "do everything" agents route poorly and are hard to evaluate.
2. **Least privilege.** Grant the smallest tool set that completes the task. Read-only agents do not get `Edit`, `Write`, or `Bash`.
3. **Precise routing.** The `description` states when to use the agent and when not to, so automatic delegation stays predictable.
4. **Structured output.** Each agent defines the exact shape of its result so the calling agent or user can act on it without re-parsing.
5. **Explicit stop conditions.** Agents say when to halt and hand back instead of guessing, especially before destructive or outward-facing actions.
6. **Right-sized model.** Use a smaller, faster model for narrow, high-volume tasks and a larger one for reasoning-heavy work.
7. **Documented trade-offs.** Every plugin README records known limitations and failure modes, not only the happy path.
8. **Tested before release.** Each agent is exercised against representative prompts, including edge cases and prompts that should *not* trigger it, before its version is bumped.

---

## Adding a new agent

1. Create the plugin folder:
   ```text
   plugins/<plugin-name>/.claude-plugin/plugin.json
   plugins/<plugin-name>/agents/<agent-name>.md
   plugins/<plugin-name>/README.md
   ```
2. Fill in `plugin.json`:
   ```json
   {
     "name": "<plugin-name>",
     "version": "0.1.0",
     "description": "One-line summary.",
     "author": { "name": "Nelson Barbosa" }
   }
   ```
3. Register the plugin in `.claude-plugin/marketplace.json`.
4. Test locally from the repository root:
   ```text
   /plugin marketplace add ./
   /plugin install <plugin-name>@claude-agents
   ```
5. Add the plugin to the [Agent catalog](#agent-catalog) table and open a pull request.

---

## Versioning and syncing

- Plugins follow [Semantic Versioning](https://semver.org/): **MAJOR** for breaking changes to behavior or output format, **MINOR** for new capabilities, **PATCH** for fixes and prompt tuning.
- Bump the version in `plugin.json` on every release so installed copies can detect updates.
- `main` is the published channel. Anything merged there is what `/plugin marketplace update claude-agents` delivers.
- To roll back, revert the change on `main` (or pin a project to an earlier commit or tag) and run the update command again.

---

## Roadmap

- [x] Marketplace manifest and first plugin
- [ ] Per-agent evaluation prompts (should-trigger and should-not-trigger cases)
- [ ] CI validation of `marketplace.json`, `plugin.json`, and agent frontmatter
- [ ] Multi-agent workflows that compose several agents from this catalog

---

## License

No license has been chosen yet. Until one is added, all rights are reserved by the author.
