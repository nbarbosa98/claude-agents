"""Gate 1 linter tests: golden fixtures pass; each mutation trips the expected rule.

Run: python3 -m unittest discover -s tools/tests -v   (needs pwsh on PATH)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LINT = os.path.join(ROOT, "tools", "lint", "lint.py")
FIX = os.path.join(ROOT, "tools", "tests", "fixtures", "packages")
CATCH = "if ($_.Exception.Message -like 'ExitCalled:*') { throw }"
MAIN_TRY_DETECT = "    Initialize-Log -PackageId $PACKAGE_ID -Role 'detect'\n"
BODY_ANCHOR_A = "    $winget = Get-WingetPath\n"


def lint(pkg_dir):
    p = subprocess.run([sys.executable, LINT, pkg_dir, "--no-pssa"], capture_output=True, text=True)
    return p.returncode, json.loads(p.stdout)


class Golden(unittest.TestCase):
    def test_fixtures_have_no_errors(self):
        for pkg in sorted(os.listdir(FIX)):
            code, res = lint(os.path.join(FIX, pkg))
            errors = [f for f in res["findings"] if f["severity"] == "error"]
            self.assertEqual(errors, [], pkg)
            self.assertEqual(res["status"], "PASS_PENDING_PSSA", pkg)
            self.assertEqual(code, 2, pkg)


class Mutations(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def pkg(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(os.path.join(FIX, name), dst)
        return dst

    def edit(self, pkg, fname, old, new, count=1):
        p = os.path.join(pkg, fname)
        with open(p, "rb") as f:
            text = f.read()
        old_b = old.encode("ascii") if isinstance(old, str) else old
        new_b = new.encode("ascii") if isinstance(new, str) else new
        self.assertIn(old_b, text, "mutation anchor not found in %s: %r" % (fname, old))
        with open(p, "wb") as f:
            f.write(text.replace(old_b, new_b, count))

    def expect(self, pkg, rule):
        code, res = lint(pkg)
        ids = {f["rule_id"] for f in res["findings"] if f["severity"] == "error"}
        self.assertIn(rule, ids, "expected %s, got %s" % (rule, sorted(ids)))
        if rule != "L-HELPER-VERBATIM":
            # A mutation anchor that landed inside a copied helper would pass for the wrong reason.
            self.assertNotIn("L-HELPER-VERBATIM", ids, "mutation touched a helper body")
        self.assertEqual(res["status"], "FAIL")
        self.assertEqual(code, 1)

    # --- HR-01 / placeholders / syntax ---
    def test_ascii(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "#>", b"# em dash \xe2\x80\x94\n#>")
        self.expect(p, "L-ASCII")

    def test_bom(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "<#", b"\xef\xbb\xbf<#")
        self.expect(p, "L-ASCII")

    def test_placeholder(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "$SUBJECT    = 'Example App'", "$SUBJECT    = '__SUBJECT__'")
        self.expect(p, "L-PLACEHOLDER")

    def test_ps7_syntax(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    $q = $null ?? 1\n" + BODY_ANCHOR_A)
        self.expect(p, "L-PS7")

    # --- HR-02 / HR-03 ---
    def test_token_not_in_contract_for_type(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "-Token 'OUTDATED'", "-Token 'DRIFTED'")
        self.expect(p, "L-STATUS-TOKEN")

    def test_token_wrong_role(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "-Token 'OUTDATED'", "-Token 'REMEDIATED'")
        self.expect(p, "L-STATUS-TOKEN")

    def test_wrong_exit_code(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "is outdated. Target {2}' -f $SUBJECT, $app.Version, $target) -Code 1",
                  "is outdated. Target {2}' -f $SUBJECT, $app.Version, $target) -Code 0")
        self.expect(p, "L-STATUS-TOKEN")

    def test_nonliteral_token(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "-Token 'OUTDATED'", "-Token $tok")
        self.expect(p, "L-STATUS-NONLITERAL")

    def test_stray_stdout(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    Write-Host 'debug'\n" + BODY_ANCHOR_A)
        self.expect(p, "L-STDOUT")

    def test_write_output_stdout(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    Write-Output 'debug'\n" + BODY_ANCHOR_A)
        self.expect(p, "L-STDOUT")

    def test_raw_exit_in_body(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    exit 1\n" + BODY_ANCHOR_A)
        self.expect(p, "L-EXIT")

    def test_catch_rethrow_missing(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "    " + CATCH + "\n", "")
        self.expect(p, "L-CATCH-RETHROW")

    def test_detect_catch_exit_1(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "    exit 0\n}", "    exit 1\n}")
        self.expect(p, "L-EXIT")

    def test_helper_modified(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "if ($line.Length -gt 512)", "if ($line.Length -gt 2000)")
        self.expect(p, "L-HELPER-VERBATIM")

    # --- HR-10 ---
    def test_initialize_log_not_first(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", MAIN_TRY_DETECT, "    $x = 1\n" + MAIN_TRY_DETECT)
        self.expect(p, "L-LOG")

    def test_log_glob_in_body(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    $g = '*_*.log'\n" + BODY_ANCHOR_A)
        self.expect(p, "L-LOG")

    # --- HR-05 / HR-06 / HR-14 ---
    def test_localappdata(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    $u = $env:LOCALAPPDATA\n" + BODY_ANCHOR_A)
        self.expect(p, "L-ENV")

    def test_temp(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    $t = $env:TEMP\n" + BODY_ANCHOR_A)
        self.expect(p, "L-ENV")

    def test_unbounded_waitforexit(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    $proc.WaitForExit()\n" + BODY_ANCHOR_A)
        self.expect(p, "L-WAIT")

    def test_raw_start_process(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    Start-Process -FilePath 'x.exe' -Wait\n" + BODY_ANCHOR_A)
        self.expect(p, "L-PROCESS")

    def test_web_without_timeout(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    Invoke-RestMethod -Uri 'https://example.invalid'\n" + BODY_ANCHOR_A)
        self.expect(p, "L-WEB-TIMEOUT")

    def test_invoke_expression(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", BODY_ANCHOR_A, "    Invoke-Expression 'x'\n" + BODY_ANCHOR_A)
        self.expect(p, "L-IEX")

    # --- HR-04 ---
    def test_literal_timeout(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "-TimeoutSeconds $TIMEOUT_CATALOG", "-TimeoutSeconds 60")
        self.expect(p, "L-TIMEOUT-CONST")

    def test_budget_exceeded(self):
        p = self.pkg("upd-example")
        self.edit(p, "remediate.ps1", "$TIMEOUT_UPGRADE   = 300", "$TIMEOUT_UPGRADE   = 500")
        self.expect(p, "L-BUDGET")

    # --- HR-15 ---
    def test_raw_winget(self):
        p = self.pkg("upd-example")
        self.edit(p, "remediate.ps1", "    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade'", "    & $winget upgrade --id x\n    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade'")
        self.expect(p, "L-WINGET-RAW")

    def test_winget_source_update(self):
        p = self.pkg("upd-example")
        self.edit(p, "remediate.ps1", "    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade'", "    $s = 'winget source update'\n    $r = Invoke-Winget -WingetPath $winget -Operation 'upgrade'")
        self.expect(p, "L-WINGET-SOURCE")

    def test_include_unknown_parity(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "$INCLUDE_UNKNOWN   = $false", "$INCLUDE_UNKNOWN   = $true")
        self.expect(p, "L-WINGET-PARITY")

    def test_include_unknown_not_passed(self):
        p = self.pkg("upd-example")
        self.edit(p, "remediate.ps1", " -IncludeUnknown:$INCLUDE_UNKNOWN", "")
        self.expect(p, "L-WINGET-PARITY")

    def test_browser_pattern_no_winget_upgrade(self):
        p = self.pkg("upd-example")
        self.edit(p, "decision-record.json", '"pattern": "A"', '"pattern": "Browser"')
        self.expect(p, "L-BROWSER")

    def test_winget_after_msiexec(self):
        p = self.pkg("upd-exampleb1")
        self.edit(p, "remediate.ps1", "    $after = Get-InstalledAppVersion",
                  "    $w = Get-WingetCatalogVersion -WingetPath 'x' -PackageId 'y' -TimeoutSeconds $TIMEOUT_DOWNLOAD\n    $after = Get-InstalledAppVersion")
        self.expect(p, "L-WINGET-AFTER-MSI")

    # --- HR-07 / HR-08 ---
    def test_trust_check_missing(self):
        p = self.pkg("upd-exampleb1")
        self.edit(p, "remediate.ps1",
                  "    $trust = Test-InstallerTrust -Path $msi -ExpectedSignerCN $EXPECTED_SIGNER_CN -ExpectedSignerO $EXPECTED_SIGNER_O -ExpectedSha256 $EXPECTED_SHA256\n",
                  "    $trust = New-Object PSObject -Property @{ Trusted = $true }\n")
        self.expect(p, "L-TRUST")

    def test_download_outside_staging(self):
        p = self.pkg("upd-exampleb1")
        self.edit(p, "remediate.ps1", "-OutFile (Join-Path $stagingDir 'installer.msi')", "-OutFile 'C:\\Windows\\Temp\\installer.msi'")
        self.expect(p, "L-STAGING")

    def test_staging_not_assigned(self):
        p = self.pkg("upd-exampleb1")
        self.edit(p, "remediate.ps1", "$stagingDir = New-SecureStagingDir -PackageId $PACKAGE_ID", "$sd = New-SecureStagingDir -PackageId $PACKAGE_ID")
        self.expect(p, "L-STAGING")

    # --- HR-16 / HR-17 / HR-20 ---
    def test_audit_state_change(self):
        p = self.pkg("aud-example")
        self.edit(p, "detect.ps1", "    $items = @(", "    Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\X' -Name a -Value 1\n    $items = @(")
        self.expect(p, "L-AUDIT-READONLY")

    def test_audit_with_remediation(self):
        p = self.pkg("aud-example")
        shutil.copy(os.path.join(p, "detect.ps1"), os.path.join(p, "remediate.ps1"))
        self.expect(p, "L-AUDIT-NOREMEDIATE")

    def test_reboot(self):
        p = self.pkg("cfg-example")
        self.edit(p, "remediate.ps1", "    if ($REBOOT_REQUIRED) {", "    Restart-Computer -Force\n    if ($REBOOT_REQUIRED) {")
        self.expect(p, "L-REBOOT")

    def test_hkcu(self):
        p = self.pkg("cfg-example")
        self.edit(p, "remediate.ps1", "HKLM:\\SOFTWARE\\ExampleVendor", "HKCU:\\SOFTWARE\\ExampleVendor")
        self.expect(p, "L-HKCU")

    # --- structure, README, decision record ---
    def test_package_id_mismatch(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "$PACKAGE_ID = 'upd-example'", "$PACKAGE_ID = 'upd-other'")
        self.expect(p, "L-ORDER")

    def test_header_role_mismatch(self):
        p = self.pkg("upd-example")
        self.edit(p, "detect.ps1", "Role:      detect", "Role:      remediate")
        self.expect(p, "L-HEADER")

    def test_readme_section_missing(self):
        p = self.pkg("upd-example")
        self.edit(p, "README.md", "## Rollback\n", "## Undo\n")
        self.expect(p, "L-README")

    def test_decision_record_mismatch(self):
        p = self.pkg("upd-example")
        self.edit(p, "decision-record.json", '"packageId": "upd-example"', '"packageId": "upd-other"')
        self.expect(p, "L-DECISION")

    def test_missing_remediation_script(self):
        p = self.pkg("upd-example")
        os.remove(os.path.join(p, "remediate.ps1"))
        self.expect(p, "L-MISSING-SCRIPT")


if __name__ == "__main__":
    unittest.main()
