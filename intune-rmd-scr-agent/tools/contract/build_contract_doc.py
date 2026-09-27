#!/usr/bin/env python3
"""Generate .claude/skills/intune-remediation/references/contract.md from contract/stdout.json.

contract/stdout.json is the single source of truth. Never edit contract.md by hand.

Usage:
  python3 tools/contract/build_contract_doc.py          # write the file
  python3 tools/contract/build_contract_doc.py --check  # exit 1 if the file is stale
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "contract" / "stdout.json"
DST = ROOT / ".claude" / "skills" / "intune-remediation" / "references" / "contract.md"


def render(c):
    out = []
    w = out.append
    w("<!-- GENERATED from contract/stdout.json by tools/contract/build_contract_doc.py. Do not edit. -->")
    w("# Stdout contract v%s" % c["contractVersion"])
    w("")
    w(c["description"])
    w("")
    f = c["format"]
    w("## Format")
    w("")
    w("- Line: `%s` (separator `%s`)" % (f["line"], f["separator"]))
    w("- Emitter: %s" % f["emitter"])
    w("- Max line length: %d characters (platform limit %d; %s)" % (f["maxLineChars"], f["platformMaxOutputChars"], f["platformSource"]))
    w("- Placeholders: %s" % f["placeholderSyntax"])
    w("")
    w("## Scripts per type")
    w("")
    w("| Type | Scripts |")
    w("|---|---|")
    for t in c["types"]:
        w("| %s | %s |" % (t, ", ".join(c["scriptsByType"][t])))
    w("")
    for t in c["types"]:
        w("## Type: %s" % t)
        w("")
        w("| Token | Script | Exit | Message template | Meaning |")
        w("|---|---|---|---|---|")
        for tok in c["tokens"]:
            if t not in tok["types"]:
                continue
            msg = tok.get("messageTemplateByType", {}).get(t, tok["messageTemplate"])
            for e in tok["emits"]:
                if e["script"] not in c["scriptsByType"][t]:
                    continue
                w("| `%s` | %s | %d | `%s` | %s |" % (tok["token"], e["script"], e["exitCode"], msg, tok["meaning"]))
        w("")
    return "\n".join(out)


def main():
    text = render(json.loads(SRC.read_text(encoding="ascii")))
    if "--check" in sys.argv:
        cur = DST.read_text(encoding="ascii") if DST.exists() else ""
        if cur != text:
            print("contract.md is stale: run tools/contract/build_contract_doc.py", file=sys.stderr)
            return 1
        print("contract.md is in sync")
        return 0
    DST.write_text(text, encoding="ascii")
    print("wrote %s" % DST.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
