# email-orchestrator

A cross-provider email assistant for Claude Code. It briefs you on new mail, categorizes it, alerts you to important emails you haven't answered, flags likely phishing, cleans up clutter, and drafts and sends email when you ask — across **Gmail, Outlook / Microsoft 365, and any other email connector** Claude has access to.

| Component | Type | Job |
| --- | --- | --- |
| `email-orchestrator` | Subagent | Finds your providers, applies the security rules, runs the skills below, and merges the results into one report |
| `inbox-briefing` | Skill | Ranked summary of recent mail, action items, and counts of bulk mail |
| `email-triage` | Skill | Sorts mail into consistent `EO/*` categories; applies them only after you confirm |
| `followup-tracker` | Skill | Important threads where the last message is to you and you haven't replied |
| `phishing-detection` | Skill | Checks sender, domain, header, content, and attachment signals, and rates each message High, Medium, or Low |
| `inbox-cleanup` | Skill | Proposes a cleanup plan → you confirm → carries it out → logs it so it can be undone |
| `email-composer` | Skill | Drafts new emails, replies, and forwards; sends only when you ask and after you approve the final preview |

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
Draft a reply to Ana saying Tuesday at 3pm works.    # drafts only
Reply to Ana that Tuesday at 3pm works and send it.  # preview → you say "send" → sent
Forward the Acme invoice to accounting@mycompany.com.
Check my email.            # brief → phishing → follow-ups → categorization plan
```

Or run a single skill directly:

```text
/email-orchestrator:inbox-briefing today
/email-orchestrator:followup-tracker 7 days
/email-orchestrator:phishing-detection
/email-orchestrator:email-triage unlabeled
/email-orchestrator:inbox-cleanup promotions older than 30 days
/email-orchestrator:email-composer reply to Ana: Tuesday at 3pm works
```

### How sending works

1. You ask it to write, reply, or forward. Asking to *draft* only creates a draft.
2. It creates a draft in the right account (where the connector supports drafts) and shows a full preview: account, To/CC/BCC, subject, body, attachments, and any warnings.
3. You reply **"send"**, or ask for changes. Any change produces a new preview that needs a new approval.
4. It sends that exact version, reports the message ID, and logs the send. **A sent email cannot be undone.**

It warns you before sending in these cases: the thread looks like phishing, the Reply-To differs from the sender, the body contains credentials or payment details, recipients are new or unusual, or the recipient list doesn't match your request.

### Getting alerts on a schedule

An agent only runs when something invokes it; it can't send a push alert by itself. To get alerts regularly:

- **Claude Code on the web / app:** create a **Routine** (a scheduled task) with a prompt such as *"Use the email-orchestrator agent: run a briefing, a phishing check, and a follow-up check for the last 24h. Do not change anything in the mailboxes and do not send anything."*
- **CLI:** `/loop 4h Use the email-orchestrator agent for a phishing and follow-up check` while a session is open, or a cron job running `claude -p "…"`.

Keep scheduled runs **read-only** (as in the prompt above). Cleanup and sending need you there to confirm; the agent is instructed never to send during unattended runs.

## How it works

1. **Provider discovery.** Each run, the agent looks at the MCP tools available and treats any server that offers mail tools as a provider. It records which actions each provider supports. Connector tool names differ between environments (`mcp__Gmail__…` vs `mcp__claude_ai_Gmail__…`), so it matches on what the tools do, not on hard-coded names.
2. **Graceful degradation.** Some connectors are read-only. Anything a provider can't do goes into a **"Do manually"** list instead of being worked around.
3. **One report.** Results are merged across providers and sorted by importance, and each item is tagged `[Gmail]`, `[Outlook]`, and so on.
4. **Memory** (`memory: user`) keeps *settings only*: your own addresses, VIP senders, category rules you've taught it, the time of the last briefing (so "latest" means "since last time"), and a log of actions so changes can be undone. It never stores email bodies or codes.

## Safety model

| Risk | Control | Type of control |
| --- | --- | --- |
| Instructions hidden in an email (prompt injection) cause the agent to act | The prompt treats all email as untrusted data; injection attempts count as a phishing signal | Prompt-level (mitigation) |
| Mail sent or forwarded without you, or to the wrong person | Sends only on your request in chat, after you approve the exact final preview; recipients come only from you or the thread, never from email text; never sends during scheduled runs | Prompt-level (mitigation) — add the `ask` rules below to **enforce** it |
| An email tricks the agent into replying to an attacker | Warnings for suspicious threads, Reply-To mismatches, and sensitive content; sending again requires your approval after you've seen the warning | Prompt-level (mitigation) |
| Mail lost | No permanent delete; Trash only (recoverable); protected categories are never touched; each change is logged with an undo step | Prompt-level + provider's Trash retention |
| Unwanted bulk changes | Every mailbox change needs you to confirm the specific plan | Prompt-level |
| Clicking malicious links | `WebFetch`, `WebSearch`, and the known browser / computer-use MCP servers are in `disallowedTools`; links are only read as text | **Enforced** for the listed tools; a browser MCP under another server name would slip through `mcp__*` |
| Local file or shell changes | No `Bash`; `Write`/`Edit` are there only for the memory files | Partly enforced |

**Important limitation:** `tools: …, mcp__*` gives the agent *every* connected MCP tool, including tools from servers that have nothing to do with email. The approval step before sending is in the agent's instructions; on its own, nothing technically enforces it. **Recommended — enforce it:** add `ask` rules to `~/.claude/settings.json` so Claude Code shows you its own permission prompt before every send, reply, or forward, whatever the agent decides:

```json
{
  "permissions": {
    "ask": [
      "mcp__*__send*",
      "mcp__*__reply*",
      "mcp__*__forward*"
    ]
  }
}
```

- `ask` and `deny` rules accept wildcards in the tool name, and are checked before `allow` rules. That means a broader allow rule can't skip the prompt. These patterns match the send, reply, and forward tools of any connector (Gmail, Microsoft 365, Resend, …), and may also prompt for other messaging tools, such as a chat app's `send_message`. That is the safe side to err on.
- Check with `/mcp` that your mail connector's send tools match these patterns. A connector whose tool is named differently (for example `create_and_send_mail`) needs its own rule.
- In `dontAsk` mode, matching calls are **denied** instead of prompting. Don't rely on these prompts in `bypassPermissions` mode.
- To make one account read-only, use `deny` instead of `ask` for that server, for example `"mcp__claude_ai_Gmail__send*"`.

## Known limitations and failure modes

- **Connector coverage varies.** Some connectors are read-only or partly read-only, may not expose raw headers (so SPF/DKIM/DMARC can't be checked), or may not let the agent read Sent mail (which weakens unanswered-email detection). The report's **Coverage** line says what was actually scanned.
- **Phishing detection is heuristic.** It will miss some attacks and wrongly flag some genuine mail. It adds to your provider's filters and your security team; it does not replace them.
- **"Important" is a judgment.** Scoring relies on VIPs, direct requests, deadlines, and history. Teach it your VIPs ("add @acme.com as VIP") to make it more accurate.
- **Outlook threading.** Replies sometimes land in a separate conversation; the follow-up tracker also searches Sent by subject, but it can still produce false "unanswered" alerts.
- **Volume.** Each run processes up to about 200 messages per window and says how many it skipped; very large backlogs need several passes.
- **Sending is permanent.** Recalling a sent message isn't possible through these connectors. The preview is your last chance to check.
- **Draft support varies.** If a connector has no draft tool, the draft only exists in the chat preview. If it can't send an existing draft, the agent sends identical content and then deletes the draft.
- **Model.** Defaults to `sonnet` to keep cost and speed reasonable over large amounts of mail. For harder phishing analysis, change `model:` in the agent file to `opus` (or `inherit`).

## Rollback

- **Mailbox changes:** ask *"undo the last cleanup"*. The agent reads its action log, shows the undo plan, and reverses it after you confirm. Items in Trash are recoverable only until your provider purges them.
- **Labels:** everything the agent creates starts with `EO/`, so it can be found and removed in one place.
- **Plugin:** `/plugin uninstall email-orchestrator@claude-agents`. Memory is kept in Claude Code's agent memory directory for this agent; delete that directory to reset preferences.

## Testing

See [`evals/prompts.md`](evals/prompts.md) for cases that should and should not route to this agent, and for safety cases (prompt injection, send approval, permanent delete).

## Changelog

- **0.2.0** — Adds `email-composer`: draft, reply, forward, and send on request after the final version is approved. Adds a confirmation protocol for subagent runs and recommends `ask` permission rules for send tools.
- **0.1.0** — First release: briefing, triage, follow-ups, phishing detection, confirmed cleanup, cross-provider discovery.
