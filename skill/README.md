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

_No skills published yet._
