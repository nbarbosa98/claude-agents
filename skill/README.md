# skill/

Plugins whose main component is one or more **skills**. Each plugin lives in its own folder:

```text
skill/<plugin-name>/
├── .claude-plugin/plugin.json   # "name" must equal <plugin-name>
├── skills/<skill-name>/SKILL.md # one folder per skill; scripts and references next to SKILL.md
└── README.md                    # usage, tools the skill uses, safety notes, changelog
```

A skill that exists only to support one agent ships inside that agent's plugin under `agent/`, not here.

Register the plugin in `.claude-plugin/marketplace.json` with `"source": "./skill/<plugin-name>"`, and follow the skill rules in [`SECURITY.md`](../SECURITY.md#skill--skills).

## Published

| Plugin | What it does | Components | Status |
| --- | --- | --- | --- |
| [`doc-skill`](doc-skill) | Documents the process just carried out, or any topic you name, in a fixed structure (Title, Summary, Scope, Details or Step by step, Additional considerations, References) and saves it as PDF, HTML, MD, TXT or DOCX | 1 skill (`/doc-skill`) | `0.1.0` — beta |
