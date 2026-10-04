# doc-skill

A documentation skill for Claude Code. It writes a structured document about the **process that was just carried out in the conversation**, or about **any topic you name**, and saves it in the format you choose: **PDF, HTML, MD, TXT or DOCX**.

| Component | Type | Job |
| --- | --- | --- |
| `doc-skill` | Skill | Gathers the content, writes it in a fixed six-section structure, and produces the file |

## Document structure

Every document has the same sections, in this order:

| Section | Content |
| --- | --- |
| **Title** | A specific name for the subject, the date, and the environment it applies to |
| **Summary** | 2–4 sentences: what it is, why it exists, the outcome |
| **Scope** | What is and is not covered, the audience, prerequisites |
| **Details** *or* **Step by step** | *Step by step* for processes a reader will repeat (numbered steps, exact commands, expected results). *Details* for concepts, systems, decisions and reference material |
| **Additional considerations** | Risks, limitations, pitfalls, rollback, security notes, open questions |
| **References** | Links, file paths, ticket numbers, tool versions |

## Install

```text
/plugin marketplace add nbarbosa98/claude-plugins
/plugin install doc-skill@claude-agents
```

## Usage

Ask in plain words, or use the slash command:

```text
Document what we just did as a PDF.
Write up the certificate renewal we just finished, in DOCX.
Create documentation on how our backup rotation works. HTML please.
/doc-skill                              # the process just executed; asks for the format
/doc-skill pdf                          # the process just executed, as PDF
/doc-skill conditional access for guests md
```

If you do not name a format, the skill asks. It never picks one for you.

Files are saved to `docs/` in the current working directory unless you give another location, named after the title (`rotate-storage-account-keys.pdf`). An existing file is not overwritten without asking.

If another installed command is also called `doc-skill`, use the full form `/doc-skill:doc-skill`.

## Formats and what they need

| Format | Needs |
| --- | --- |
| MD, TXT, HTML | Nothing. Claude writes the file directly. HTML is a single self-contained file with no external resources |
| DOCX | One of: a Word-document skill in the session, `pandoc`, or Python with `python-docx` |
| PDF | One of: a PDF skill in the session, `pandoc` with a PDF engine, `weasyprint`, a Chromium-based browser (headless print), or LibreOffice |

The skill uses only converters that are **already installed**. If none can produce the format, it says what is missing and offers the closest format it can produce (HTML instead of PDF, MD instead of DOCX).

## Tools the skill uses

The skill sets no `allowed-tools`, so nothing is pre-approved: every file write and every converter command goes through your normal permission prompts.

| Tool | Why |
| --- | --- |
| `Write` | Saves the document (and the temporary Markdown or HTML source for PDF and DOCX) |
| `Read`, `Grep`, `Glob` | Reads files you point at when documenting a topic |
| `Bash` | Only for PDF and DOCX: checks which converter is installed and runs it |

## Safety model

| Risk | Control | Enforced by |
| --- | --- | --- |
| Secrets from the session end up in a document | Secrets, tokens, keys and connection strings are replaced with placeholders; the final check looks for any that survived | Prompt |
| Internal identifiers leave the organisation | The skill asks whether to replace tenant IDs, hostnames, IPs and names when the document will be shared externally | Prompt |
| Prompt injection through files or pages read as source material | Source content is treated as data, never as instructions | Prompt |
| Remote code or data exfiltration during conversion | No package installs, no downloads, no online conversion services; only local, already installed converters | Prompt; `Bash` permission prompts in Claude Code |
| Overwriting an existing file | Asks before overwriting | Prompt |
| Publishing without consent | The skill writes one local file and does not upload, email or commit it | Prompt |
| Invented content | Records only what happened or what a source states; unverified items are marked "Not verified"; links are never invented | Prompt |

To make the conversion gate strict, keep `Bash` out of your `allow` rules, or add `ask` rules for the converters you have, for example `Bash(pandoc:*)`.

## Known limitations

- **The controls above are prompt-level.** Read a document before you share it, especially for secrets and internal identifiers.
- **PDF and DOCX depend on what is installed.** Layout differs between converters; a PDF made with a headless browser will not look the same as one made with `pandoc` and LaTeX.
- **"The process just executed" means what is in the conversation.** After a long session that was summarised, early steps may be missing detail. Ask for the document soon after the work, or point the skill at logs and files.
- **One document per run.** It does not maintain a documentation set, a table of contents or cross-links between documents.
- **No diagrams or screenshots.** Text, tables and code blocks only.

## Changelog

### 0.1.0

- First version: six-section structure, Details or Step by step body, output as PDF, HTML, MD, TXT or DOCX.
