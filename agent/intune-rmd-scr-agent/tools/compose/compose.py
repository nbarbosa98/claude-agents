#!/usr/bin/env python3
"""Deterministic composer: builds detect.ps1 / remediate.ps1 from a package's src/ (ADR-031).

Generators write only package-specific parts into packages/<id>/src/:
  meta.json                 {"type", "subject", "summary", "generator"}
  constants.ps1             constants shared by both scripts (assignments only)
  detect.constants.ps1      optional, detection-only constants
  remediate.constants.ps1   optional, remediation-only constants
  detect.body.ps1           main body for detection (indented 4 spaces)
  remediate.body.ps1        main body for remediation (absent for audit)
The composer fills references/templates/<role>.skeleton.ps1, copies every helper the script
needs (directly or through another helper) verbatim from references/helpers.ps1 in canonical
order, and writes packages/<id>/<role>.ps1. Composed scripts are never edited by hand.

Usage:
  python3 tools/compose/compose.py packages/<id>           write the composed scripts
  python3 tools/compose/compose.py packages/<id> --check   exit 1 if they are stale
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REF = ROOT / ".claude" / "skills" / "intune-remediation" / "references"
FACTS = ROOT / "tools" / "lint" / "Get-ScriptFacts.ps1"
ALWAYS = {"detect": ["Initialize-Log", "Write-RemediationLog", "Exit-WithCode"],
          "remediate": ["Initialize-Log", "Write-RemediationLog", "Exit-WithCode", "Remove-SecureStagingDir"]}
META_KEYS = ("type", "subject", "summary")


def helper_functions():
    r = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-File", str(FACTS), "-Path", str(REF / "helpers.ps1")],
                       capture_output=True, text=True, check=True)
    return [(f["name"], f["text"].replace("\r\n", "\n")) for f in json.loads(r.stdout)["functions"]]


def contract_version():
    return json.loads((ROOT / "contract" / "stdout.json").read_text(encoding="ascii"))["contractVersion"]


def used_helpers(text, helpers, always):
    names = [n for n, _ in helpers]
    body = dict(helpers)
    need = set(always)
    frontier = [text] + [body[a] for a in always]
    while frontier:
        t = frontier.pop()
        for n in names:
            if n not in need and re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(n), t):
                need.add(n)
                frontier.append(body[n])
    return [(n, t) for n, t in helpers if n in need]


def read_ascii(p):
    data = p.read_bytes()
    bad = [i for i, b in enumerate(data) if b > 0x7F]
    if bad:
        raise ValueError("%s is not ASCII (byte offset %d)" % (p, bad[0]))
    return data.decode("ascii").replace("\r\n", "\n")


def load_meta(src):
    meta = json.loads(read_ascii(src / "meta.json"))
    missing = [k for k in META_KEYS if not meta.get(k)]
    if missing:
        raise ValueError("src/meta.json missing: %s" % ", ".join(missing))
    return meta


def compose_role(src, package_id, role, helpers, cv):
    meta = load_meta(src)
    consts = read_ascii(src / "constants.ps1").rstrip("\n")
    rc = src / ("%s.constants.ps1" % role)
    if rc.exists():
        consts += "\n" + read_ascii(rc).rstrip("\n")
    body = read_ascii(src / ("%s.body.ps1" % role)).rstrip("\n")
    tpl = read_ascii(REF / "templates" / ("%s.skeleton.ps1" % role))
    hs = used_helpers(consts + "\n" + body, helpers, ALWAYS[role])
    rep = {
        "__PACKAGE_ID__": package_id,
        "__SCRIPT_TYPE__": meta["type"],
        "__CONTRACT_VERSION__": cv,
        "__GENERATOR_ID__": meta.get("generator", "unknown"),
        "__ONE_LINE_SUMMARY__": meta["summary"],
        "__SUBJECT__": meta["subject"],
        "__TYPE_CONSTANTS__": consts,
        "__HELPERS__": "\n\n".join(t for _, t in hs),
        "__DETECT_BODY__": body,
        "__REMEDIATE_BODY__": body,
    }
    out = tpl
    for k, v in rep.items():
        out = out.replace(k, v)
    return out


def compose_dir(src, package_id, helpers=None, cv=None):
    """Returns {"detect.ps1": text, ["remediate.ps1": text]} for a src directory."""
    helpers = helpers or helper_functions()
    cv = cv or contract_version()
    out = {}
    for role in ("detect", "remediate"):
        if (src / ("%s.body.ps1" % role)).exists():
            out["%s.ps1" % role] = compose_role(src, package_id, role, helpers, cv)
    if "detect.ps1" not in out:
        raise ValueError("src/detect.body.ps1 is required")
    return out


def compose_package(pkg_dir, check=False):
    """Composes packages/<id>/src into packages/<id>/. Returns a list of stale or written files."""
    pkg_dir = Path(pkg_dir).resolve()
    files = compose_dir(pkg_dir / "src", pkg_dir.name)
    changed = []
    for name, text in files.items():
        p = pkg_dir / name
        if not p.exists() or p.read_text(encoding="ascii") != text:
            changed.append(name)
            if not check:
                p.write_text(text, encoding="ascii", newline="\n")
    # A remediation script without a remediation body is stale (for example after an audit rename).
    if not (pkg_dir / "src" / "remediate.body.ps1").exists() and (pkg_dir / "remediate.ps1").exists():
        changed.append("remediate.ps1 (no src body)")
        if not check:
            (pkg_dir / "remediate.ps1").unlink()
    return changed


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 3
    try:
        changed = compose_package(args[0], check="--check" in argv)
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print("compose failed: %s" % e, file=sys.stderr)
        return 1
    if "--check" in argv:
        if changed:
            print("stale: " + ", ".join(changed), file=sys.stderr)
            return 1
        print("composed scripts in sync")
        return 0
    print("composed: " + (", ".join(changed) if changed else "nothing changed"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
