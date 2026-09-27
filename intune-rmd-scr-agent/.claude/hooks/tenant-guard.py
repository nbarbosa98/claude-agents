#!/usr/bin/env python3
"""PreToolUse hook (Bash): blocks Graph write calls unless the tenant is allowlisted.

Layer 3 of the safety model (docs/decisions.md ADR-020). It is a guardrail on the command
text Claude writes, not a sandbox: permission rules and hooks match command strings
(https://code.claude.com/docs/en/permissions, "Bash rules"), so the Graph write tools also
verify the signed-in token's tenant themselves (Phase 5).

Rules:
  1. Any Graph write path outside tools/graph/write/ is denied (raw REST calls, Graph SDK
     write cmdlets). All writes must go through the project's write tools.
  2. A call to tools/graph/write/ must carry -TenantId <guid> (or --tenant <guid>) and that
     GUID must be in config/local.json tenant.allowlist.
  3. Missing or malformed config/local.json denies every write (fail closed).

Input/Output contract: https://code.claude.com/docs/en/hooks (PreToolUse stdin JSON;
exit 2 blocks the call and stderr is shown to Claude).
"""
import json
import os
import re
import sys

GUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
WRITE_TOOL = re.compile(r"tools/graph/write/", re.I)
TENANT_ARG = re.compile(r"(?:-TenantId|--tenant)(?:\s+|=|:)['\"]?(" + GUID + r")", re.I)
RAW_WRITE = [
    re.compile(r"graph\.microsoft\.com", re.I),  # any raw REST call to Graph from Bash
    re.compile(r"\b(New|Update|Set|Remove|Invoke|Add|Clear|Move|Restore|Stop|Start|Sync|Publish)-Mg[A-Za-z]+", re.I),
    re.compile(r"\bInvoke-MgGraphRequest\b", re.I),
    re.compile(r"\baz\s+rest\b", re.I),
]
# Read tools may mention graph.microsoft.com in their own files, but the command line never
# needs to: they are invoked as scripts.
READ_TOOL = re.compile(r"tools/graph/read/", re.I)


def deny(reason):
    print("tenant-guard: " + reason, file=sys.stderr)
    sys.exit(2)


def load_allowlist(project_dir):
    path = os.path.join(project_dir, "config", "local.json")
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
        allow = cfg["tenant"]["allowlist"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not isinstance(allow, list):
        return None
    good = [a.lower() for a in allow if isinstance(a, str) and re.fullmatch(GUID, a)]
    placeholder = "00000000-0000-0000-0000-000000000000"
    good = [g for g in good if g != placeholder]
    return good or None


def check(command, project_dir):
    """Returns None when allowed, or a reason string when denied."""
    is_write_tool = bool(WRITE_TOOL.search(command))
    if not is_write_tool:
        if READ_TOOL.search(command) and not any(p.search(command) for p in RAW_WRITE[1:]):
            return None
        for p in RAW_WRITE:
            if p.search(command):
                return ("direct Graph access from Bash is blocked; use tools/graph/read/ "
                        "or tools/graph/write/ (pattern: %s)" % p.pattern)
        return None
    allow = load_allowlist(project_dir)
    if allow is None:
        return "config/local.json missing, malformed, or allowlist empty; Graph writes are blocked"
    tenants = {m.lower() for m in TENANT_ARG.findall(command)}
    if not tenants:
        return "Graph write without -TenantId <guid>; blocked"
    bad = sorted(t for t in tenants if t not in allow)
    if bad:
        return "tenant not on allowlist: %s" % ", ".join(bad)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        deny("could not parse hook input; failing closed")
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    command = str((data.get("tool_input") or {}).get("command", ""))
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
    reason = check(command, project_dir)
    if reason:
        deny(reason)
    sys.exit(0)


if __name__ == "__main__":
    main()
