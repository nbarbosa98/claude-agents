#!/usr/bin/env python3
"""Compose the Gate 1/2 test fixture packages from tools/tests/fixtures/src/.

Each src/<package-id>/ holds meta.json, constants.ps1 (shared), optional
<role>.constants.ps1 (one role only), detect.body.ps1,
[remediate.body.ps1], README.md and decision-record.json. The composer fills the
skeleton templates through tools/compose/compose.py (the same composer packages use) and
writes tools/tests/fixtures/packages/<id>/.

Usage:
  python3 tools/tests/fixtures/build_fixtures.py          # write
  python3 tools/tests/fixtures/build_fixtures.py --check  # exit 1 if outputs are stale
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "compose"))
from compose import compose_dir, contract_version, helper_functions  # noqa: E402

SRC = Path(__file__).resolve().parent / "src"
OUT = Path(__file__).resolve().parent / "packages"


def build():
    helpers = helper_functions()
    cv = contract_version()
    result = {}
    for pkg in sorted(p for p in SRC.iterdir() if p.is_dir()):
        files = compose_dir(pkg, pkg.name, helpers, cv)
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
