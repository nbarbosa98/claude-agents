"""Gate 2 runner tests: golden fixtures pass; broken behaviour and missing coverage fail.

Run: python3 -m unittest tools.tests.test_gate2 -v   (needs pwsh and Pester 5)
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GATE2 = os.path.join(ROOT, "tools", "pester", "Invoke-Gate2.ps1")
FIX = os.path.join(ROOT, "tools", "tests", "fixtures", "packages")


def gate2(pkg):
    p = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-File", GATE2, "-PackagePath", pkg],
                       capture_output=True, text=True)
    return p.returncode, json.loads(p.stdout)


class Gate2(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def pkg(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(os.path.join(FIX, name), dst)
        return dst

    def edit(self, pkg, fname, old, new):
        p = os.path.join(pkg, fname)
        with open(p, encoding="ascii") as f:
            text = f.read()
        self.assertIn(old, text)
        with open(p, "w", encoding="ascii") as f:
            f.write(text.replace(old, new, 1))

    def test_golden_pattern_a_passes(self):
        code, res = gate2(os.path.join(FIX, "upd-example"))
        self.assertEqual((code, res["status"], res["failed"]), (0, "PASS", 0))

    def test_success_without_post_check_fails(self):
        p = self.pkg("upd-example")
        self.edit(p, "remediate.ps1", "if ($after.Status -eq 'Machine' -and $after.Version -ge $target) {", "if ($true) {")
        code, res = gate2(p)
        self.assertEqual(res["status"], "FAIL")
        self.assertGreater(res["failed"], 0)
        self.assertEqual(code, 1)

    def test_fail_closed_instead_of_open_fails(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1",
                  "Exit-WithCode -Token 'NOT_DETERMINED' -Message ('{0} state not determined: winget not found' -f $SUBJECT) -Code 0",
                  "Exit-WithCode -Token 'OUTDATED' -Message ('{0} winget not found' -f $SUBJECT) -Code 1")
        code, res = gate2(p)
        self.assertEqual(res["status"], "FAIL")

    def test_uncovered_exit_path_fails(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "    $winget = Get-WingetPath\n",
                  "    if ($app.Status -eq 'Staged') { Exit-WithCode -Token 'STAGED' -Message 'x' -Code 0 }\n    $winget = Get-WingetPath\n")
        code, res = gate2(p)
        self.assertIn("detect:STAGED", res["uncovered"])
        self.assertEqual(res["status"], "FAIL")

    def test_missing_matrix_fails(self):
        p = self.pkg("upd-example")
        self.edit(p, "decision-record.json", '"pattern": "A"', '"pattern": "B2"')
        code, res = gate2(p)
        self.assertEqual(res["status"], "FAIL")
        self.assertIn("no Gate 2 matrix", res["failures"][0]["message"])

    def test_windows_only_scenarios_are_not_a_pass(self):
        code, res = gate2(os.path.join(FIX, "aud-example"))
        if res["platform"] == "windows":
            self.skipTest("on Windows the scenarios run")
        self.assertEqual((code, res["status"]), (2, "PASS_PENDING_WINDOWS"))
        self.assertGreater(res["skipped"], 0)


if __name__ == "__main__":
    unittest.main()
