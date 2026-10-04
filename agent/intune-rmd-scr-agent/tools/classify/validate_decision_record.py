#!/usr/bin/env python3
"""Validate packages/<id>/decision-record.json against references/decision-record.md.

Usage: python3 tools/classify/validate_decision_record.py <path/to/decision-record.json>
Prints JSON {"valid": bool, "errors": [...], "stop": bool}. "stop" is true when the
pipeline must stop and ask the owner (low confidence or open questions).
Exit: 0 valid and not stopping, 1 invalid, 2 valid but stop.
Also imported by tools/lint/lint.py (L-DECISION).
"""
import json
import re
import sys
from pathlib import Path

TYPES = {"app-update": "upd-", "vuln-remediation": "vuln-", "config-change": "cfg-", "audit": "aud-", "general": "gen-"}
PATTERNS = {"A", "Browser", "B1", "B2", "B3"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}$")


def validate(dr):
    e = []
    if not isinstance(dr, dict):
        return ["not a JSON object"], False
    for k in ("schemaVersion", "packageId", "type", "subject", "request", "confidence", "openQuestions", "evidence"):
        if k not in dr:
            e.append("missing %s" % k)
    t = dr.get("type")
    pid = dr.get("packageId") or ""
    if t not in TYPES:
        e.append("unknown type %r" % t)
    elif not pid.startswith(TYPES[t]):
        e.append("packageId %r must start with %r" % (pid, TYPES[t]))
    if not ID_RE.match(pid):
        e.append("packageId %r: lowercase letters, digits, hyphens, max 49" % pid)
    if dr.get("confidence") not in ("high", "medium", "low"):
        e.append("confidence must be high, medium or low")
    if not isinstance(dr.get("openQuestions", []), list):
        e.append("openQuestions must be a list")
    for i, ev in enumerate(dr.get("evidence") or []):
        for k in ("field", "value", "source", "retrievedAt"):
            if k not in ev:
                e.append("evidence[%d] missing %s" % (i, k))
    if t == "app-update":
        if dr.get("pattern") not in PATTERNS:
            e.append("app-update pattern must be one of %s" % sorted(PATTERNS))
        det = dr.get("detection") or {}
        for k in ("displayNameLike", "mainExePaths", "versionSource"):
            if k not in det:
                e.append("detection.%s missing" % k)
        if det.get("versionSource") not in ("FileVersion", "DisplayVersion"):
            e.append("detection.versionSource must be FileVersion or DisplayVersion")
        inst = dr.get("install") or {}
        if dr.get("pattern") == "A":
            if not inst.get("wingetId"):
                e.append("Pattern A needs install.wingetId")
            if not isinstance(inst.get("includeUnknown"), bool):
                e.append("Pattern A needs install.includeUnknown (bool)")
        elif dr.get("pattern") in PATTERNS:
            signer = inst.get("expectedSigner") or {}
            if not signer.get("CN") or not signer.get("O"):
                e.append("download patterns need install.expectedSigner CN and O (HR-08)")
            if not isinstance(inst.get("sha256Published"), bool):
                e.append("install.sha256Published (bool) missing")
    if t == "vuln-remediation":
        v = dr.get("vuln") or {}
        if not v.get("cveIds"):
            e.append("vuln.cveIds missing")
        if not v.get("advisoryUrls"):
            e.append("vuln.advisoryUrls missing (no advisory, no package)")
        if v.get("fixKind") not in ("version", "mitigation"):
            e.append("vuln.fixKind must be version or mitigation")
    if t == "config-change" and not dr.get("desiredState"):
        e.append("config-change needs desiredState")
    stop = dr.get("confidence") == "low" or bool(dr.get("openQuestions"))
    return e, stop


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 3
    try:
        dr = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as ex:
        print(json.dumps({"valid": False, "errors": [str(ex)], "stop": True}))
        return 1
    errors, stop = validate(dr)
    print(json.dumps({"valid": not errors, "errors": errors, "stop": stop}, indent=2))
    if errors:
        return 1
    return 2 if stop else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
