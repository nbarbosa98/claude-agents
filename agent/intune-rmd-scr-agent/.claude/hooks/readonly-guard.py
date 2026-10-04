#!/usr/bin/env python3
"""Subagent-scoped PreToolUse hook (Bash): only allowlisted read-only tool scripts may run.

Used by ops-agent and classifier (declared in their frontmatter). Usage:
  readonly-guard.py <profile>
Profiles:
  ops        -> tools/graph/read/ scripts and tools/contract/ checks
  classifier -> tools/classify/ scripts
A command is allowed only if it is a single command (no shell chaining, redirection or
substitution) that starts with an allowed interpreter and an allowed script path.
Exit 2 blocks the call (https://code.claude.com/docs/en/hooks).
"""
import json
import re
import sys

PROFILES = {
    "ops": [r"tools/graph/read/[A-Za-z0-9_.-]+\.(ps1|py)", r"tools/contract/[A-Za-z0-9_.-]+\.py"],
    "classifier": [r"tools/classify/[A-Za-z0-9_.-]+\.(ps1|py)"],
}
INTERPRETER = r"^(?:pwsh\s+(?:-NoProfile\s+)?(?:-NonInteractive\s+)?-File|python3)\s+(?:\./)?"
FORBIDDEN = re.compile(r"[;&|`<>]|\$\(|\n|\r")


def main():
    profile = sys.argv[1] if len(sys.argv) > 1 else ""
    if profile not in PROFILES:
        print("readonly-guard: unknown profile %r; failing closed" % profile, file=sys.stderr)
        sys.exit(2)
    try:
        data = json.load(sys.stdin)
    except ValueError:
        print("readonly-guard: unparseable input; failing closed", file=sys.stderr)
        sys.exit(2)
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = str((data.get("tool_input") or {}).get("command", "")).strip()
    if FORBIDDEN.search(cmd):
        print("readonly-guard: shell operators are not allowed for this agent", file=sys.stderr)
        sys.exit(2)
    for script in PROFILES[profile]:
        if re.match(INTERPRETER + script + r"(\s|$)", cmd):
            sys.exit(0)
    print("readonly-guard: command not on the %s allowlist" % profile, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
