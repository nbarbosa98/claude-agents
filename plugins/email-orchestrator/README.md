# email-orchestrator

A cross-provider email assistant for Claude Code. It briefs you on new mail, categorizes it, alerts you to important emails you haven't answered, flags likely phishing, and cleans up clutter — across **Gmail, Outlook / Microsoft 365, and any other email connector** Claude has access to.

| Component | Type | Job |
| --- | --- | --- |
| `email-orchestrator` | Subagent | Finds your providers, applies the security rules, runs the skills below, and merges the results into one report |
| `inbox-briefing` | Skill | Ranked summary of recent mail, action items, and counts of bulk mail |
| `email-triage` | Skill | Sorts mail into consistent `EO/*` categories; applies them only after you confirm |
| `followup-tracker` | Skill | Important threads where the last message is to you and you haven't replied |
| `phishing-detection` | Skill | Checks sender, domain, header, content, and attachment signals, and rates each message High, Medium, or Low |
| `inbox-cleanup` | Skill | Proposes a cleanup plan → you confirm → carries it out → logs it so it can be undone |

## Prerequisites

1. **At least one email connector** available in Claude Code — for example the Gmail connector, the Microsoft 365 connector (Outlook), or another mail MCP server. On claude.ai: **Settings → Connectors**. In the CLI: `/mcp` to check what's connected.
2. The plugin itself:
   ```text
   /plugin marketplace add nbarbosa98/claude-agents
   /plugin install email-orchestrator@claude-agents
   ```

The agent does **not** ship its own MCP server. It uses whatever mail connectors you already have, which keeps authentication in the connector and out of this repo.

## Usage

Talk to Claude normally; the agent's description routes email requests to it:

```text
Use the email-orchestrator agent to brief me on email since yesterday.
What important emails haven't I replied to this week?
Is the "DocuSign – invoice pending" email in my Outlook legit?
Clean up promotions older than 30 days in Gmail.
Check my email.            # brief → phishing → follow-ups → categorization plan
```

Or run a single skill directly:

```text
/email-orchestrator:inbox-briefing today
/email-orchestrator:followup-tracker 7 days
/email-orchestrator:phishing-detection
/email-orchestrator:email-triage unlabeled
/email-orchestrator:inbox-cleanup promotions older than 30 days
```

### Getting alerts on a schedule

An agent only runs when something invokes it; it can't send a push alert by itself. To get alerts regularly:

- **Claude Code on the web / app:** create a **Routine** (a scheduled task) with a prompt such as *"Use the email-orchestrator agent: run a briefing, a phishing check, and a follow-up check for the last 24h. Do not change anything in the mailboxes."*
- **CLI:** `/loop 4h Use the email-orchestrator agent for a phishing and follow-up check` while a session is open, or a cron job running `claude -p "…"`.

Keep scheduled runs **read-only** (as in the prompt above). Cleanup needs you there to confirm the plan.

## How it works

1. **Provider discovery.** Each run, the agent looks at the MCP tools available and treats any server that offers mail tools as a provider. It records which actions each provider supports. Connector tool names differ between environments (`mcp__Gmail__…` vs `mcp__claude_ai_Gmail__…`), so it matches on what the tools do, not on hard-coded names.
2. **Graceful degradation.** Some connectors are read-only. Anything a provider can't do goes into a **"Do manually"** list instead of being worked around.
3. **One report.** Results are merged across providers and sorted by importance, and each item is tagged `[Gmail]`, `[Outlook]`, and so on.
4. **Memory** (`memory: user`) keeps *settings only*: your own addresses, VIP senders, category rules you've taught it, the time of the last briefing (so "latest" means "since last time"), and a log of actions so changes can be undone. It never stores email bodies or codes.

## Safety model

| Risk | Control | Type of control |
| --- | --- | --- |
| Instructions hidden in an email (prompt injection) cause the agent to act | The prompt treats all email as untrusted data; injection attempts count as a phishing signal | Prompt-level (mitigation) |
| Mail sent or forwarded without you | The agent never sends, replies, or forwards — drafts only | Prompt-level (mitigation) |
| Mail lost | No permanent delete; Trash only (recoverable); protected categories are never touched; each change is logged with an undo step | Prompt-level + provider's Trash retention |
| Unwanted bulk changes | Every mailbox change needs you to confirm the specific plan | Prompt-level |
| Clicking malicious links | `WebFetch`, `WebSearch`, and the known browser / computer-use MCP servers are in `disallowedTools`; links are only read as text | **Enforced** for the listed tools; a browser MCP under another server name would slip through `mcp__*` |
| Local file or shell changes | No `Bash`; `Write`/`Edit` are there only for the memory files | Partly enforced |

**Important limitation:** `tools: …, mcp__*` gives the agent *every* connected MCP tool, including send tools and tools from servers that have nothing to do with email. The rules against sending are in the prompt; nothing technically blocks them. For a hard guarantee, add deny rules for your send and forward tools in `~/.claude/settings.json`, using the exact tool names shown by `/mcp` in your setup. For example:

```json
{
  "permissions": {
    "deny": [
      "mcp__claude_ai_Gmail__send_message",
      "mcp__claude_ai_Gmail__reply",
      "mcp__claude_ai_Gmail__forward"
    ]
  }
}
```

Check the names against `/mcp` before relying on this: a deny rule with a wrong name silently blocks nothing.

## Known limitations and failure modes

- **Connector coverage varies.** Some connectors are read-only or partly read-only, may not expose raw headers (so SPF/DKIM/DMARC can't be checked), or may not let the agent read Sent mail (which weakens unanswered-email detection). The report's **Coverage** line says what was actually scanned.
- **Phishing detection is heuristic.** It will miss some attacks and wrongly flag some genuine mail. It adds to your provider's filters and your security team; it does not replace them.
- **"Important" is a judgment.** Scoring relies on VIPs, direct requests, deadlines, and history. Teach it your VIPs ("add @acme.com as VIP") to make it more accurate.
- **Outlook threading.** Replies sometimes land in a separate conversation; the follow-up tracker also searches Sent by subject, but it can still produce false "unanswered" alerts.
- **Volume.** Each run processes up to about 200 messages per window and says how many it skipped; very large backlogs need several passes.
- **Model.** Defaults to `sonnet` to keep cost and speed reasonable over large amounts of mail. For harder phishing analysis, change `model:` in the agent file to `opus` (or `inherit`).

## Rollback

- **Mailbox changes:** ask *"undo the last cleanup"*. The agent reads its action log, shows the undo plan, and reverses it after you confirm. Items in Trash are recoverable only until your provider purges them.
- **Labels:** everything the agent creates starts with `EO/`, so it can be found and removed in one place.
- **Plugin:** `/plugin uninstall email-orchestrator@claude-agents`. Memory is kept in Claude Code's agent memory directory for this agent; delete that directory to reset preferences.

## Testing

See [`evals/prompts.md`](evals/prompts.md) for cases that should and should not route to this agent, and for safety cases (prompt injection, send requests, permanent delete).

## Changelog

- **0.1.0** — First release: briefing, triage, follow-ups, phishing detection, confirmed cleanup, cross-provider discovery.
