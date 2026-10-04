# mcp/

Plugins whose main component is an **MCP server** configuration. Each plugin lives in its own folder:

```text
mcp/<plugin-name>/
├── .claude-plugin/plugin.json   # "name" must equal <plugin-name>
├── .mcp.json                    # server definition: pinned version, secrets only as ${ENV_VAR}
└── README.md                    # what the server does, every tool (read/write), required env vars, ask/deny rules
```

Example `.mcp.json`:

```json
{
  "mcpServers": {
    "example": {
      "command": "npx",
      "args": ["-y", "example-mcp-server@1.4.2"],
      "env": { "EXAMPLE_API_KEY": "${EXAMPLE_API_KEY}" }
    }
  }
}
```

`.mcp.json` starts a process as soon as the plugin is enabled. Pin exact versions (never `@latest`), keep secrets out of the file, and follow the MCP rules in [`SECURITY.md`](../SECURITY.md#mcp--mcp-servers).

Register the plugin in `.claude-plugin/marketplace.json` with `"source": "./mcp/<plugin-name>"`.

_No MCP servers published yet._
