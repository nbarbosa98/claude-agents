#!/usr/bin/env python3
"""Compose the Gate 1/2 test fixture packages from tools/tests/fixtures/src/.

Each src/<package-id>/ holds meta.json, constants.ps1 (shared), optional
<role>.constants.ps1 (one role only), detect.body.ps1,
[remediate.body.ps1], README.md and decision-record.json. The composer fills the
skeleton templates, copies the helpers each script needs (transitively) verbatim from
references/helpers.ps1 in canonical order, and writes tools/tests/fixtures/packages/<id>/.

Usage:
  python3 tools/tests/fixtures/build_fixtures.py          # write
  python3 tools/tests/fixtures/build_fixtures.py --check  # exit 1 if outputs are stale
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REF = ROOT / ".claude" / "skills" / "intune-remediation" / "references"
SRC = Path(__file__).resolve().parent / "src"
OUT = Path(__file__).resolve().parent / "packages"
FACTS = ROOT / "tools" / "lint" / "Get-ScriptFacts.ps1"
ALWAYS = {"detect": ["Initialize-Log", "Write-RemediationLog", "Exit-WithCode"],
          "remediate": ["Initialize-Log", "Write-RemediationLog", "Exit-WithCode", "Remove-SecureStagingDir"]}


def helper_functions():
    r = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-File", str(FACTS), "-Path", str(REF / "helpers.ps1")],
                       capture_output=True, text=True, check=True)
    fns = json.loads(r.stdout)["functions"]
    return [(f["name"], f["text"].replace("\r\n", "\n")) for f in fns]


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


def compose(pkg_dir, role, helpers, contract_version):
    meta = json.loads((pkg_dir / "meta.json").read_text(encoding="ascii"))
    consts = (pkg_dir / "constants.ps1").read_text(encoding="ascii").rstrip("\n")
    role_consts = pkg_dir / ("%s.constants.ps1" % role)
    if role_consts.exists():
        consts += "\n" + role_consts.read_text(encoding="ascii").rstrip("\n")
    body = (pkg_dir / ("%s.body.ps1" % role)).read_text(encoding="ascii").rstrip("\n")
    tpl = (REF / "templates" / ("%s.skeleton.ps1" % role)).read_text(encoding="ascii")
    hs = used_helpers(consts + "\n" + body, helpers, ALWAYS[role])
    out = tpl
    rep = {
        "__PACKAGE_ID__": pkg_dir.name,
        "__SCRIPT_TYPE__": meta["type"],
        "__CONTRACT_VERSION__": contract_version,
        "__GENERATOR_ID__": "fixture-composer",
        "__ONE_LINE_SUMMARY__": meta["summary"],
        "__SUBJECT__": meta["subject"],
        "__TYPE_CONSTANTS__": consts,
        "__HELPERS__": "\n\n".join(t for _, t in hs),
        "__DETECT_BODY__": body,
        "__REMEDIATE_BODY__": body,
    }
    for k, v in rep.items():
        out = out.replace(k, v)
    return out


def build():
    helpers = helper_functions()
    cv = json.loads((ROOT / "contract" / "stdout.json").read_text(encoding="ascii"))["contractVersion"]
    result = {}
    for pkg in sorted(p for p in SRC.iterdir() if p.is_dir()):
        files = {}
        for role in ("detect", "remediate"):
            if (pkg / ("%s.body.ps1" % role)).exists():
                files["%s.ps1" % role] = compose(pkg, role, helpers, cv)
        for f in ("README.md", "decision-record.json"):
            files[f] = (pkg / f).read_text(encoding="ascii")
        if (pkg / "gate4.json").exists():
            files["gate4.json"] = (pkg / "gate4.json").read_text(encoding="ascii")
        result[pkg.name] = files
    return result


def main():
    built = build()
    if "--check" in sys.argv:
        stale = []
        for pkg, files in built.items():
            for name, text in files.items():
                p = OUT / pkg / name
                if not p.exists() or p.read_text(encoding="ascii") != text:
                    stale.append(str(p.relative_to(ROOT)))
        if stale:
            print("stale fixtures: " + ", ".join(stale), file=sys.stderr)
            return 1
        print("fixtures in sync")
        return 0
    if OUT.exists():
        shutil.rmtree(OUT)
    for pkg, files in built.items():
        (OUT / pkg).mkdir(parents=True)
        for name, text in files.items():
            (OUT / pkg / name).write_text(text, encoding="ascii", newline="\n")
        print("wrote %s (%s)" % (pkg, ", ".join(sorted(files))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
