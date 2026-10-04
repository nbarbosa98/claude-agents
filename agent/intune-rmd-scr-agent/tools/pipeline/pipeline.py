#!/usr/bin/env python3
"""Deterministic driver for the /new-remediation loop (ADR-032).

The orchestrator (an LLM) decides and delegates; this tool does the bookkeeping that must not
depend on judgement: composing, running Gates 1/2/4, recording Gate 3, extracting repair
evidence, enforcing the repair budget, deciding deliverability, and writing metrics.

  pipeline.py start <pkg>                     begin a run (iteration 0); validates inputs
  pipeline.py gates <pkg>                     compose, then Gate 1 and Gate 2 (stops at the first failure)
  pipeline.py review <pkg> <reviewer.txt>     record Gate 3 from the reviewer's report
  pipeline.py gate4 <pkg> [--backend azure|local|skip]   run Gate 4, or record NOT_RUN
  pipeline.py evidence <pkg>                  print failing evidence of the current iteration (for the generator)
  pipeline.py repair <pkg> --cites E1,E2      open the next iteration; every evidence id must be cited
  pipeline.py status <pkg>                    deliverable or not, with blockers
  pipeline.py finish <pkg> --outcome delivered|stopped|budget-exhausted
                                              append metrics to out/metrics.jsonl; on delivered,
                                              copy the final gate artifacts into packages/<id>/evidence/

Exit codes: 0 ok / gate passed; 1 gate failed or not deliverable; 3 usage or input error;
4 repair budget exhausted.
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "compose"))
sys.path.insert(0, str(ROOT / "tools" / "classify"))
from compose import compose_package  # noqa: E402
from validate_decision_record import validate as validate_dr  # noqa: E402

# Run artifacts and metrics go to out/ (git-ignored); tests point this elsewhere.
OUT_ROOT = Path(os.environ.get("INTUNE_RMD_OUT", str(ROOT / "out"))).resolve()
MAX_REPAIRS = 3
GATES = ("gate1", "gate2", "gate3", "gate4")
REVIEW_LINE = re.compile(r"^\[(PASS|FAIL|WARN)\]\s+(.*)$")
VERDICT = re.compile(r"^VERDICT:\s*(PASS|FAIL)\b")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class UsageError(Exception):
    pass


class Pipeline:
    def __init__(self, pkg):
        self.pkg = Path(pkg).resolve()
        self.id = self.pkg.name
        self.results_path = self.pkg / "gate-results.json"
        self.out = OUT_ROOT / self.id

    # ---------- state ----------
    def load(self):
        if not self.results_path.exists():
            raise UsageError("no run in progress: run 'pipeline.py start %s' first" % self.pkg)
        return json.loads(self.results_path.read_text(encoding="ascii"))

    def save(self, st):
        self.results_path.write_text(json.dumps(st, indent=2) + "\n", encoding="ascii")

    def cur(self, st):
        return st["iterations"][-1]

    def iter_dir(self, st):
        d = self.out / ("iter-%d" % self.cur(st)["n"])
        d.mkdir(parents=True, exist_ok=True)
        return d

    def rel(self, p):
        p = Path(p).resolve()
        try:
            return str(p.relative_to(ROOT))
        except ValueError:
            return str(p)  # outside the repo (tests); ROOT / absolute path stays absolute

    # ---------- commands ----------
    def start(self):
        dr_path = self.pkg / "decision-record.json"
        if not dr_path.exists():
            raise UsageError("decision-record.json missing")
        dr = json.loads(dr_path.read_text(encoding="utf-8"))
        errors, stop = validate_dr(dr)
        if errors:
            raise UsageError("decision record invalid: " + "; ".join(errors))
        if stop:
            raise UsageError("decision record has low confidence or open questions: ask the owner first")
        if not (self.pkg / "src" / "meta.json").exists():
            raise UsageError("src/meta.json missing: the generator has not written the package yet")
        st = {"packageId": self.id, "type": dr["type"], "pattern": dr.get("pattern"), "startedAt": now(),
              "startedEpoch": time.time(), "maxRepairs": MAX_REPAIRS, "outcome": None,
              "iterations": [{"n": 0, "startedAt": now(), "gates": {g: {"status": "NOT_RUN"} for g in GATES}, "cites": []}]}
        self.save(st)
        return 0, {"started": self.id, "iteration": 0}

    def gates(self):
        st = self.load()
        it = self.cur(st)
        d = self.iter_dir(st)
        try:
            changed = compose_package(self.pkg)
        except (ValueError, OSError) as e:
            it["gates"]["gate1"] = {"status": "FAIL", "summary": "compose failed: %s" % e, "artifact": None}
            self.save(st)
            return 1, {"gate1": "FAIL", "reason": str(e)}
        # Gate 1
        g1 = d / "gate1.json"
        r = subprocess.run([sys.executable, str(ROOT / "tools/lint/lint.py"), str(self.pkg), "--out", str(g1)],
                           capture_output=True, text=True)
        res = json.loads(g1.read_text(encoding="ascii")) if g1.exists() else {"status": "ERROR", "findings": []}
        errs = [f for f in res.get("findings", []) if f["severity"] == "error"]
        it["gates"]["gate1"] = {"status": res["status"], "artifact": self.rel(g1), "summary": "%d error(s), %d warning(s); budget %s"
                                % (len(errs), len(res.get("findings", [])) - len(errs), res.get("budget"))}
        it["composed"] = changed
        it["scriptSha256"] = self.script_hashes()
        if res["status"] != "PASS":
            it["gates"]["gate2"] = {"status": "NOT_RUN", "summary": "Gate 1 did not pass"}
            self.save(st)
            return 1, {"gate1": res["status"], "gate2": "NOT_RUN"}
        # Gate 2
        g2 = d / "gate2.json"
        subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "tools/pester/Invoke-Gate2.ps1"),
                        "-PackagePath", str(self.pkg), "-OutFile", str(g2)], capture_output=True, text=True)
        r2 = json.loads(g2.read_text(encoding="ascii")) if g2.exists() else {"status": "ERROR"}
        it["gates"]["gate2"] = {"status": r2["status"], "artifact": self.rel(g2) if g2.exists() else None,
                                "summary": "passed %s, failed %s, skipped %s, uncovered %s" % (r2.get("passed"), r2.get("failed"), r2.get("skipped"), r2.get("uncovered"))}
        self.save(st)
        return (0 if r2["status"] == "PASS" else 1), {"gate1": res["status"], "gate2": r2["status"]}

    def review(self, report_path):
        st = self.load()
        it = self.cur(st)
        if it["gates"]["gate1"]["status"] != "PASS" or it["gates"]["gate2"]["status"] not in ("PASS", "PASS_PENDING_WINDOWS"):
            raise UsageError("Gate 3 runs only after Gates 1 and 2 (Gate 2 may be PASS_PENDING_WINDOWS)")
        text = Path(report_path).read_text(encoding="utf-8", errors="replace")
        d = self.iter_dir(st)
        dst = d / "gate3.txt"
        dst.write_text(text, encoding="utf-8")
        lines = [REVIEW_LINE.match(l.strip()) for l in text.splitlines()]
        items = [{"level": m.group(1), "text": m.group(2)} for m in lines if m]
        verdict = [VERDICT.match(l.strip()) for l in text.splitlines()]
        verdict = [v.group(1) for v in verdict if v]
        fails = [i for i in items if i["level"] == "FAIL"]
        warns = [i for i in items if i["level"] == "WARN"]
        if len(verdict) != 1 or not items:
            status, why = "FAIL", "reviewer report malformed (needs [PASS]/[FAIL]/[WARN] lines and one VERDICT line)"
        elif fails:
            status, why = "FAIL", "%d FAIL" % len(fails)
        elif st["type"] == "general" and warns:
            status, why = "FAIL", "general package: %d WARN are blocking" % len(warns)
        elif verdict[0] != "PASS":
            status, why = "FAIL", "verdict FAIL"
        else:
            status, why = "PASS", "%d checks, %d WARN" % (len(items), len(warns))
        it["gates"]["gate3"] = {"status": status, "artifact": self.rel(dst), "summary": why}
        self.save(st)
        return (0 if status == "PASS" else 1), {"gate3": status, "summary": why}

    def gate4(self, backend):
        st = self.load()
        it = self.cur(st)
        if it["gates"]["gate3"]["status"] != "PASS":
            raise UsageError("Gate 4 runs only after Gate 3 passes")
        if backend == "skip":
            it["gates"]["gate4"] = {"status": "NOT_RUN", "summary": "skipped: no lab VM available", "artifact": None}
            self.save(st)
            return 1, {"gate4": "NOT_RUN"}
        d = self.iter_dir(st) / "gate4"
        subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "tools/vm/Invoke-VmGate.ps1"),
                        "-PackagePath", str(self.pkg), "-Backend", backend, "-OutDir", str(d), "-IncludeWindowsTests"],
                       capture_output=True, text=True)
        f = d / "gate4.json"
        r = json.loads(f.read_text(encoding="ascii")) if f.exists() else {"status": "ERROR", "scenarios": []}
        it["gates"]["gate4"] = {"status": r["status"], "artifact": self.rel(f) if f.exists() else None,
                                "summary": ", ".join("%s=%s" % (s["name"], s["status"]) for s in r.get("scenarios", []))}
        self.save(st)
        return (0 if r["status"] == "PASS" else 1), {"gate4": r["status"]}

    def evidence(self):
        st = self.load()
        it = self.cur(st)
        ev = []

        def add(gate, **kw):
            ev.append(dict(id="E%d" % (len(ev) + 1), gate=gate, **kw))

        g = it["gates"]
        if g["gate1"].get("artifact") and g["gate1"]["status"] != "PASS":
            r = json.loads((ROOT / g["gate1"]["artifact"]).read_text(encoding="ascii"))
            for f in r["findings"]:
                if f["severity"] == "error":
                    add("gate1", rule_id=f["rule_id"], file=f["file"], line=f["line"], evidence=f["evidence"])
        elif g["gate1"]["status"] == "FAIL":
            add("gate1", rule_id="COMPOSE", file="src", line=0, evidence=g["gate1"]["summary"])
        if g["gate2"].get("artifact") and g["gate2"]["status"] not in ("PASS", "PASS_PENDING_WINDOWS"):
            r = json.loads((ROOT / g["gate2"]["artifact"]).read_text(encoding="ascii"))
            for f in r.get("failures", []):
                add("gate2", rule_id="SCENARIO", file=f.get("scenario", ""), line=0, evidence=f.get("message", ""))
            for u in r.get("uncovered", []):
                add("gate2", rule_id="UNCOVERED", file=u, line=0, evidence="exit path has no Gate 2 scenario: %s" % u)
        if g["gate3"].get("artifact") and g["gate3"]["status"] != "PASS":
            text = (ROOT / g["gate3"]["artifact"]).read_text(encoding="utf-8", errors="replace")
            for l in text.splitlines():
                m = REVIEW_LINE.match(l.strip())
                if m and (m.group(1) == "FAIL" or (m.group(1) == "WARN" and st["type"] == "general")):
                    add("gate3", rule_id="REVIEW-" + m.group(1), file="", line=0, evidence=m.group(2))
            if not ev:
                add("gate3", rule_id="REVIEW", file="", line=0, evidence=g["gate3"]["summary"])
        if g["gate4"].get("artifact") and g["gate4"]["status"] not in ("PASS",):
            r = json.loads((ROOT / g["gate4"]["artifact"]).read_text(encoding="ascii"))
            for s in r.get("scenarios", []):
                if s["status"] in ("FAIL", "ERROR"):
                    bad = [a for a in s.get("assertions", []) if not a["pass"]]
                    for a in bad:
                        add("gate4", rule_id="VM-" + s["name"], file="", line=0, evidence="%s: %s" % (a["name"], a.get("detail", "")))
                    if not bad:
                        add("gate4", rule_id="VM-" + s["name"], file="", line=0, evidence=s.get("detail", s["status"]))
        path = self.iter_dir(st) / "evidence.json"
        path.write_text(json.dumps(ev, indent=2) + "\n", encoding="ascii")
        it["evidence"] = self.rel(path)
        self.save(st)
        return (1 if ev else 0), {"iteration": it["n"], "evidence": ev}

    def repair(self, cites):
        st = self.load()
        it = self.cur(st)
        if not it.get("evidence"):
            raise UsageError("run 'evidence' first: a repair must address recorded evidence")
        ev = json.loads((ROOT / it["evidence"]).read_text(encoding="ascii"))
        if not ev:
            raise UsageError("no failing evidence: nothing to repair")
        ids = {e["id"] for e in ev}
        missing = sorted(ids - set(cites))
        unknown = sorted(set(cites) - ids)
        if missing or unknown:
            raise UsageError("cites must cover exactly the evidence ids; missing %s, unknown %s" % (missing, unknown))
        repairs = len(st["iterations"]) - 1
        if repairs >= MAX_REPAIRS:
            st["outcome"] = "budget-exhausted"
            self.save(st)
            return 4, {"budgetExhausted": True, "repairsUsed": repairs}
        it["cites"] = sorted(cites)
        st["iterations"].append({"n": it["n"] + 1, "startedAt": now(), "gates": {g: {"status": "NOT_RUN"} for g in GATES}, "cites": []})
        self.save(st)
        return 0, {"iteration": it["n"] + 1, "repairsUsed": repairs + 1, "repairsLeft": MAX_REPAIRS - repairs - 1}

    def status(self):
        st = self.load()
        it = self.cur(st)
        blockers = []
        for g in GATES:
            stt = it["gates"][g]["status"]
            if stt == "PASS":
                continue
            if g == "gate2" and stt == "PASS_PENDING_WINDOWS" and self.windows_gate2_passed(it):
                continue  # the WindowsOnly scenarios passed on the VM in Gate 4
            blockers.append("%s is %s" % (g, stt))
        blockers += ["%s has no artifact" % g for g in GATES if it["gates"][g]["status"] != "NOT_RUN" and not it["gates"][g].get("artifact")]
        try:
            stale = compose_package(self.pkg, check=True)
        except (ValueError, OSError) as e:
            stale = ["compose error: %s" % e]
        if stale:
            blockers.append("composed scripts out of date: %s" % ", ".join(stale))
        gated = it.get("scriptSha256")
        if not gated:
            blockers.append("no script hashes recorded for this iteration (run gates again)")
        elif gated != self.script_hashes():
            blockers.append("scripts changed after the gates ran")
        return (0 if not blockers else 1), {"package": self.id, "iteration": it["n"], "deliverable": not blockers,
                                            "gates": {g: it["gates"][g]["status"] for g in GATES}, "blockers": blockers,
                                            "scriptSha256": gated or {}}

    def script_hashes(self):
        """sha256 of each composed script, recorded when the gates run, so /deploy can prove it
        uploads exactly the bytes that passed (ADR-035)."""
        return {n: hashlib.sha256((self.pkg / n).read_bytes()).hexdigest()
                for n in ("detect.ps1", "remediate.ps1") if (self.pkg / n).exists()}

    def windows_gate2_passed(self, it):
        a = it["gates"]["gate4"].get("artifact")
        if it["gates"]["gate4"]["status"] != "PASS" or not a:
            return False
        r = json.loads((ROOT / a).read_text(encoding="ascii"))
        return any(sc["name"] == "gate2-windows-scenarios" and sc["status"] == "PASS" for sc in r.get("scenarios", []))

    def finish(self, outcome):
        if outcome not in ("delivered", "stopped", "budget-exhausted"):
            raise UsageError("outcome must be delivered, stopped or budget-exhausted")
        st = self.load()
        code, s = self.status()
        if outcome == "delivered" and not s["deliverable"]:
            raise UsageError("not deliverable: " + "; ".join(s["blockers"]))
        by_rule = {}
        first_pass = {}
        for it in st["iterations"]:
            if it.get("evidence"):
                for e in json.loads((ROOT / it["evidence"]).read_text(encoding="ascii")):
                    by_rule[e["rule_id"]] = by_rule.get(e["rule_id"], 0) + 1
        for g in GATES:
            first_pass[g] = st["iterations"][0]["gates"][g]["status"]
        rec = {"ts": now(), "package": self.id, "type": st["type"], "pattern": st["pattern"], "outcome": outcome,
               "repairs": len(st["iterations"]) - 1, "firstIteration": first_pass, "final": s["gates"],
               "failuresByRule": by_rule, "wallSeconds": round(time.time() - st["startedEpoch"])}
        OUT_ROOT.mkdir(parents=True, exist_ok=True)
        with open(OUT_ROOT / "metrics.jsonl", "a", encoding="ascii") as f:
            f.write(json.dumps(rec) + "\n")
        st["outcome"] = outcome
        st["finishedAt"] = now()
        if outcome == "delivered":
            ev = self.pkg / "evidence"
            if ev.exists():
                shutil.rmtree(ev)
            ev.mkdir()
            it = self.cur(st)
            for g in GATES:
                a = it["gates"][g].get("artifact")
                if a:
                    shutil.copy(ROOT / a, ev / Path(a).name)
                    it["gates"][g]["committedArtifact"] = self.rel(ev / Path(a).name)
        self.save(st)
        return 0, rec


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 3
    cmd, pkg = argv[1], argv[2]
    p = Pipeline(pkg)

    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default

    try:
        if cmd == "start":
            code, out = p.start()
        elif cmd == "gates":
            code, out = p.gates()
        elif cmd == "review":
            if len(argv) < 4:
                raise UsageError("review needs the reviewer report path")
            code, out = p.review(argv[3])
        elif cmd == "gate4":
            code, out = p.gate4(opt("--backend", "azure"))
        elif cmd == "evidence":
            code, out = p.evidence()
        elif cmd == "repair":
            code, out = p.repair([c for c in (opt("--cites", "") or "").split(",") if c])
        elif cmd == "status":
            code, out = p.status()
        elif cmd == "finish":
            code, out = p.finish(opt("--outcome", ""))
        else:
            raise UsageError("unknown command %s" % cmd)
    except UsageError as e:
        print(json.dumps({"error": str(e)}))
        return 3
    print(json.dumps(out, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
