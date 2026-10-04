"""Tests for tools/compose/compose.py and tools/pipeline/pipeline.py (the /new-remediation driver).

Run: python3 -m unittest tools.tests.test_pipeline -v   (needs pwsh, Pester 5, PSScriptAnalyzer)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PIPE = os.path.join(ROOT, "tools", "pipeline", "pipeline.py")
COMPOSE = os.path.join(ROOT, "tools", "compose", "compose.py")
SRC = os.path.join(ROOT, "tools", "tests", "fixtures", "src")
FIX = os.path.join(ROOT, "tools", "tests", "fixtures", "packages")

PASS_REVIEW = "[PASS] HR-02 tokens allowed (detect.ps1:300)\n[PASS] HR-08 n/a\nVERDICT: PASS\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out = os.path.join(self.tmp, "out")
        self.env = dict(os.environ, INTUNE_RMD_OUT=self.out)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def package(self, name):
        """A package as a generator leaves it: src/ + README + decision record (+ gate4.json)."""
        dst = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(dst, "src"))
        for f in os.listdir(os.path.join(SRC, name)):
            s = os.path.join(SRC, name, f)
            if f in ("README.md", "decision-record.json", "gate4.json"):
                shutil.copy(s, os.path.join(dst, f))
            else:
                shutil.copy(s, os.path.join(dst, "src", f))
        return dst

    def run_pipe(self, *args):
        p = subprocess.run([sys.executable, PIPE] + list(args), capture_output=True, text=True, env=self.env)
        try:
            out = json.loads(p.stdout)
        except ValueError:
            out = {"raw": p.stdout, "stderr": p.stderr}
        return p.returncode, out

    def write(self, path, text):
        with open(path, "w", encoding="ascii") as f:
            f.write(text)
        return path

    def results(self, pkg):
        with open(os.path.join(pkg, "gate-results.json"), encoding="ascii") as f:
            return json.load(f)


class Compose(Base):
    def test_compose_matches_fixture_output(self):
        pkg = self.package("upd-example")
        p = subprocess.run([sys.executable, COMPOSE, pkg], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        for role in ("detect.ps1", "remediate.ps1"):
            with open(os.path.join(pkg, role), encoding="ascii") as a, open(os.path.join(FIX, "upd-example", role), encoding="ascii") as b:
                self.assertEqual(a.read(), b.read(), role)
        p = subprocess.run([sys.executable, COMPOSE, pkg, "--check"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)

    def test_check_detects_hand_edits(self):
        pkg = self.package("upd-example")
        subprocess.run([sys.executable, COMPOSE, pkg], capture_output=True, text=True, check=True)
        with open(os.path.join(pkg, "detect.ps1"), "a", encoding="ascii") as f:
            f.write("# hand edit\n")
        p = subprocess.run([sys.executable, COMPOSE, pkg, "--check"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)

    def test_non_ascii_source_is_rejected(self):
        pkg = self.package("upd-example")
        with open(os.path.join(pkg, "src", "detect.body.ps1"), "ab") as f:
            f.write(b"    # \xe2\x80\x94\n")
        p = subprocess.run([sys.executable, COMPOSE, pkg], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("not ASCII", p.stderr)


class HappyPath(Base):
    def test_gates_review_and_no_vm(self):
        pkg = self.package("upd-example")
        self.assertEqual(self.run_pipe("start", pkg)[0], 0)
        code, out = self.run_pipe("gates", pkg)
        self.assertEqual((code, out["gate1"], out["gate2"]), (0, "PASS", "PASS"))
        code, out = self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), PASS_REVIEW))
        self.assertEqual((code, out["gate3"]), (0, "PASS"))
        code, out = self.run_pipe("gate4", pkg, "--backend", "skip")
        self.assertEqual(out["gate4"], "NOT_RUN")
        code, st = self.run_pipe("status", pkg)
        self.assertEqual(code, 1)
        self.assertFalse(st["deliverable"])
        self.assertIn("gate4 is NOT_RUN", st["blockers"])
        code, out = self.run_pipe("finish", pkg, "--outcome", "delivered")
        self.assertEqual(code, 3, "a package with Gate 4 NOT_RUN must not be deliverable")
        code, rec = self.run_pipe("finish", pkg, "--outcome", "stopped")
        self.assertEqual(code, 0)
        self.assertEqual(rec["repairs"], 0)
        with open(os.path.join(self.out, "metrics.jsonl"), encoding="ascii") as f:
            self.assertEqual(json.loads(f.readlines()[-1])["outcome"], "stopped")

    def test_deliverable_when_every_gate_passed_with_artifacts(self):
        pkg = self.package("aud-example")
        self.run_pipe("start", pkg)
        code, out = self.run_pipe("gates", pkg)
        self.assertEqual(out["gate2"], "PASS_PENDING_WINDOWS")
        self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), PASS_REVIEW))
        # Simulate a Gate 4 run on the VM (the VM itself is exercised by tools/vm/tests).
        g4 = self.write(os.path.join(self.tmp, "gate4.json"), json.dumps({"status": "PASS", "scenarios": [
            {"name": "finding", "status": "PASS"}, {"name": "gate2-windows-scenarios", "status": "PASS"}]}))
        st = self.results(pkg)
        st["iterations"][-1]["gates"]["gate4"] = {"status": "PASS", "artifact": g4, "summary": "simulated"}
        self.write(os.path.join(pkg, "gate-results.json"), json.dumps(st))
        code, s = self.run_pipe("status", pkg)
        self.assertEqual((code, s["deliverable"]), (0, True), s)
        code, rec = self.run_pipe("finish", pkg, "--outcome", "delivered")
        self.assertEqual(code, 0)
        self.assertTrue(os.path.exists(os.path.join(pkg, "evidence", "gate1.json")))

    def test_pending_windows_needs_vm_proof(self):
        pkg = self.package("aud-example")
        self.run_pipe("start", pkg)
        self.run_pipe("gates", pkg)
        self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), PASS_REVIEW))
        g4 = self.write(os.path.join(self.tmp, "gate4.json"), json.dumps({"status": "PASS", "scenarios": [{"name": "finding", "status": "PASS"}]}))
        st = self.results(pkg)
        st["iterations"][-1]["gates"]["gate4"] = {"status": "PASS", "artifact": g4}
        self.write(os.path.join(pkg, "gate-results.json"), json.dumps(st))
        code, s = self.run_pipe("status", pkg)
        self.assertIn("gate2 is PASS_PENDING_WINDOWS", s["blockers"])


class RepairLoop(Base):
    def broken(self):
        pkg = self.package("upd-example")
        with open(os.path.join(pkg, "src", "detect.body.ps1"), "r+", encoding="ascii") as f:
            t = f.read()
            f.seek(0)
            f.write("    Write-Host 'debug'\n" + t)
        return pkg

    def test_failure_evidence_and_cites(self):
        pkg = self.broken()
        self.run_pipe("start", pkg)
        code, out = self.run_pipe("gates", pkg)
        self.assertEqual((code, out["gate1"], out["gate2"]), (1, "FAIL", "NOT_RUN"))
        code, ev = self.run_pipe("evidence", pkg)
        self.assertEqual(code, 1)
        rules = {e["rule_id"] for e in ev["evidence"]}
        self.assertIn("L-STDOUT", rules)
        ids = [e["id"] for e in ev["evidence"]]
        self.assertEqual(self.run_pipe("repair", pkg, "--cites", ids[0] + ",E99")[0], 3)
        code, out = self.run_pipe("repair", pkg, "--cites", ",".join(ids))
        self.assertEqual((code, out["iteration"]), (0, 1))

    def test_review_needs_gates_first(self):
        pkg = self.broken()
        self.run_pipe("start", pkg)
        self.run_pipe("gates", pkg)
        code, out = self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), PASS_REVIEW))
        self.assertEqual(code, 3)

    def test_repair_requires_evidence(self):
        pkg = self.broken()
        self.run_pipe("start", pkg)
        self.run_pipe("gates", pkg)
        self.assertEqual(self.run_pipe("repair", pkg, "--cites", "E1")[0], 3)

    def test_budget_of_three_repairs(self):
        pkg = self.broken()
        self.run_pipe("start", pkg)
        for i in range(3):
            self.run_pipe("gates", pkg)
            ids = [e["id"] for e in self.run_pipe("evidence", pkg)[1]["evidence"]]
            self.assertEqual(self.run_pipe("repair", pkg, "--cites", ",".join(ids))[0], 0, "repair %d" % (i + 1))
        self.run_pipe("gates", pkg)
        ids = [e["id"] for e in self.run_pipe("evidence", pkg)[1]["evidence"]]
        code, out = self.run_pipe("repair", pkg, "--cites", ",".join(ids))
        self.assertEqual(code, 4)
        self.assertTrue(out["budgetExhausted"])
        self.assertEqual(self.results(pkg)["outcome"], "budget-exhausted")


class Review(Base):
    def ready(self, name="upd-example"):
        pkg = self.package(name)
        self.run_pipe("start", pkg)
        self.run_pipe("gates", pkg)
        return pkg

    def test_fail_line_fails(self):
        pkg = self.ready()
        code, out = self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"),
                                  "[FAIL] HR-13 REMEDIATED without post-check (remediate.ps1:97)\nVERDICT: FAIL (1 FAIL, 0 WARN)\n"))
        self.assertEqual((code, out["gate3"]), (1, "FAIL"))
        ev = self.run_pipe("evidence", pkg)[1]["evidence"]
        self.assertEqual(ev[0]["rule_id"], "REVIEW-FAIL")

    def test_malformed_report_fails(self):
        pkg = self.ready()
        code, out = self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), "Looks good to me!\n"))
        self.assertEqual(out["gate3"], "FAIL")
        self.assertIn("malformed", out["summary"])

    def test_pass_verdict_with_fail_line_fails(self):
        pkg = self.ready()
        code, out = self.run_pipe("review", pkg, self.write(os.path.join(self.tmp, "r.txt"), "[FAIL] x\nVERDICT: PASS\n"))
        self.assertEqual(out["gate3"], "FAIL")


class Inputs(Base):
    def test_start_refuses_open_questions(self):
        pkg = self.package("upd-example")
        p = os.path.join(pkg, "decision-record.json")
        with open(p, encoding="ascii") as f:
            dr = json.load(f)
        dr["openQuestions"] = ["which signer?"]
        self.write(p, json.dumps(dr))
        code, out = self.run_pipe("start", pkg)
        self.assertEqual(code, 3)
        self.assertIn("open questions", out["error"])

    def test_start_refuses_missing_src(self):
        pkg = self.package("upd-example")
        shutil.rmtree(os.path.join(pkg, "src"))
        self.assertEqual(self.run_pipe("start", pkg)[0], 3)

    def test_hand_edited_script_blocks_delivery(self):
        pkg = self.package("upd-example")
        self.run_pipe("start", pkg)
        self.run_pipe("gates", pkg)
        with open(os.path.join(pkg, "remediate.ps1"), "a", encoding="ascii") as f:
            f.write("# edit\n")
        code, s = self.run_pipe("status", pkg)
        self.assertTrue(any("out of date" in b for b in s["blockers"]))


if __name__ == "__main__":
    unittest.main()
