#!/usr/bin/env python3
"""Phase 1 self-check of the project's own files (not a gate for generated packages).

Checks: ASCII, JSON validity, contract integrity and generated-doc sync, agent and skill
frontmatter and tool budgets, reference links, PowerShell parse + 5.1 syntax of helpers
and templates, a composed Pattern A sample, and the hook unit tests.

Usage:
  python3 tools/selfcheck/selfcheck.py          quick checks (about 1 minute)
  python3 tools/selfcheck/selfcheck.py --full   also Gate 1/Gate 2 test suites, helper Pester
                                                tests and the live winget-pkgs lookup
Exit 1 on any failure.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / ".claude" / "skills" / "intune-remediation"
REF = SKILL / "references"
results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))


def frontmatter(path):
    text = path.read_text(encoding="ascii")
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    fm = {}
    key = None
    for line in m.group(1).splitlines():
        km = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if km:
            key = km.group(1)
            fm[key] = km.group(2)
        elif key:
            fm[key] += "\n" + line
    return fm


def main():
    # 1. ASCII over every tracked-type file in the project
    bad = []
    for p in ROOT.rglob("*"):
        if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts:
            data = p.read_bytes()
            if any(b > 0x7F for b in data):
                bad.append(str(p.relative_to(ROOT)))
    check("ASCII-only files", not bad, ", ".join(bad))

    # 2. JSON validity
    for rel in ["contract/stdout.json", "config/example.json", ".claude/settings.json"]:
        try:
            json.loads((ROOT / rel).read_text(encoding="ascii"))
            check("valid JSON " + rel, True)
        except ValueError as e:
            check("valid JSON " + rel, False, str(e))

    # 3. Contract integrity
    c = json.loads((ROOT / "contract/stdout.json").read_text(encoding="ascii"))
    errs = []
    seen = set()
    for t in c["tokens"]:
        if t["token"] in seen:
            errs.append("duplicate " + t["token"])
        seen.add(t["token"])
        if not re.fullmatch(r"[A-Z][A-Z_]+", t["token"]):
            errs.append("bad token name " + t["token"])
        for ty in t["types"]:
            if ty not in c["types"]:
                errs.append("%s: unknown type %s" % (t["token"], ty))
        for e in t["emits"]:
            if e["exitCode"] not in (0, 1):
                errs.append("%s: exit %s" % (t["token"], e["exitCode"]))
            if e["script"] not in ("detect", "remediate"):
                errs.append("%s: script %s" % (t["token"], e["script"]))
    for ty in c["types"]:
        det1 = [t["token"] for t in c["tokens"] if ty in t["types"] and {"script": "detect", "exitCode": 1} in t["emits"]]
        if not det1:
            errs.append("type %s has no detect exit-1 token" % ty)
    check("contract integrity", not errs, "; ".join(errs))
    r = subprocess.run([sys.executable, str(ROOT / "tools/contract/build_contract_doc.py"), "--check"], capture_output=True, text=True)
    check("contract.md in sync with stdout.json", r.returncode == 0, r.stderr.strip())

    # 4. Agents
    agents = {p.stem: frontmatter(p) for p in (ROOT / ".claude/agents").glob("*.md")}
    expected = {"intune-rmd-scr-agent", "app-update-agent", "vuln-remediation-agent", "config-change-agent",
                "audit-agent", "general-agent", "classifier", "reviewer", "ops-agent"}
    check("agent set", set(agents) == expected, "got %s" % sorted(agents))
    for name, fm in agents.items():
        ok = fm is not None and fm.get("name") == name and fm.get("description") and fm.get("tools")
        check("agent frontmatter " + name, bool(ok))
        if not ok:
            continue
        tools = {t.strip() for t in re.split(r",(?![^(]*\))", fm["tools"])}
        if name.endswith("-agent") and name not in ("ops-agent", "intune-rmd-scr-agent"):
            check("generator tool budget " + name, tools == {"Read", "Grep", "Glob", "Write", "Edit"}, str(sorted(tools)))
        if name == "reviewer":
            check("reviewer is read-only", tools == {"Read", "Grep", "Glob"}, str(sorted(tools)))
        if name in ("ops-agent", "classifier"):
            prof = "ops" if name == "ops-agent" else "classifier"
            check("readonly hook on " + name, ("readonly-guard.py\\\" %s" % prof) in fm.get("hooks", "") or ("readonly-guard.py\" %s" % prof) in fm.get("hooks", "")
                  or ("readonly-guard.py\\\" " + prof) in fm.get("hooks", ""), fm.get("hooks", ""))
            check("no Write/Edit on " + name, not ({"Edit"} & tools) and (name != "ops-agent" or "Write" not in tools))
    settings = json.loads((ROOT / ".claude/settings.json").read_text(encoding="ascii"))
    check("settings: main thread agent", settings.get("agent") == "intune-rmd-scr-agent")
    check("settings: ask on graph write tools", "Bash(* tools/graph/write/*)" in settings["permissions"]["ask"])

    # 5. Skills
    for sk in (ROOT / ".claude/skills").iterdir():
        fm = frontmatter(sk / "SKILL.md")
        check("skill frontmatter " + sk.name, bool(fm and fm.get("description")))
        if sk.name in ("deploy", "promote"):
            check("model invocation disabled for " + sk.name, fm.get("disable-model-invocation") == "true")
    links = re.findall(r"\]\((references/[^)]+)\)", (SKILL / "SKILL.md").read_text(encoding="ascii"))
    missing = [l for l in links if not (SKILL / l).exists()]
    check("SKILL.md reference links resolve", not missing, ", ".join(missing))
    n = len((SKILL / "SKILL.md").read_text(encoding="ascii").splitlines())
    check("SKILL.md under 200 lines", n < 200, "%d lines" % n)

    # 6. PowerShell
    pwsh = shutil.which("pwsh")
    if not pwsh:
        check("pwsh available", False, "install PowerShell 7")
    else:
        with tempfile.TemporaryDirectory() as td:
            files = [str(REF / "helpers.ps1")] + [str(p) for p in sorted((ROOT / "tools/tests/fixtures/packages").glob("*/*.ps1"))]
            for t in (REF / "templates").glob("*.ps1"):
                filled = Path(td) / t.name
                filled.write_text(re.sub(r"__[A-Z][A-Z0-9_]*__", "x", t.read_text(encoding="ascii")), encoding="ascii")
                files.append(str(filled))
            for f in files:
                # pwsh -File cannot bind an array from several arguments, so check one file per call.
                r = subprocess.run([pwsh, "-NoProfile", "-File", str(ROOT / "tools/selfcheck/Test-Ps51Syntax.ps1"), "-Path", f],
                                   capture_output=True, text=True)
                check("PowerShell parse + 5.1 syntax: " + Path(f).name, r.returncode == 0, (r.stdout.strip() + r.stderr.strip())[:500])

    # 7. Fixtures composed from the current templates and helpers
    r = subprocess.run([sys.executable, str(ROOT / "tools/tests/fixtures/build_fixtures.py"), "--check"], capture_output=True, text=True)
    check("test fixtures in sync with templates and helpers", r.returncode == 0, r.stderr.strip())

    # 8. Python test suites (hooks and offline classifier tests always; the rest with --full)
    suites = ["tools.tests.test_hooks", "tools.tests.test_classify.ManifestParsing",
              "tools.tests.test_classify.VendorProbe", "tools.tests.test_classify.DecisionRecord"]
    if "--full" in sys.argv:
        suites += ["tools.tests.test_lint", "tools.tests.test_gate2", "tools.tests.test_classify.LiveLookup"]
    for s in suites:
        r = subprocess.run([sys.executable, "-m", "unittest", s], capture_output=True, text=True, cwd=str(ROOT))
        tail = r.stderr.strip().splitlines()
        check("unittest " + s, r.returncode == 0, " | ".join(tail[-3:]) if tail else "")

    # 9. Helper Pester tests (--full)
    if "--full" in sys.argv and pwsh:
        cmd = ("Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99; $c = New-PesterConfiguration; "
               "$c.Run.Path = 'tools/pester/helpers'; $c.Run.PassThru = $true; $c.Output.Verbosity = 'None'; "
               "$r = Invoke-Pester -Configuration $c; '{0} {1} {2}' -f $r.PassedCount, $r.FailedCount, $r.SkippedCount; "
               "if ($r.FailedCount -gt 0) { exit 1 }")
        r = subprocess.run([pwsh, "-NoProfile", "-Command", cmd], capture_output=True, text=True, cwd=str(ROOT))
        check("helper Pester tests (passed failed skipped: %s)" % r.stdout.strip().splitlines()[-1:] , r.returncode == 0, r.stderr[-300:])

    width = max(len(n) for n, _, _ in results)
    fails = 0
    for name, ok, detail in results:
        fails += 0 if ok else 1
        print("%s  %s%s" % ("PASS" if ok else "FAIL", name.ljust(width), ("  " + detail) if (detail and not ok) else ""))
    print("\n%d checks, %d failed" % (len(results), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
