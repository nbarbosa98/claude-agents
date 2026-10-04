"""Classifier tool tests: offline parsing, validation, decision-record rules, and an
optional live winget-pkgs lookup (skipped when the network or git is unavailable).

Run: python3 -m unittest tools.tests.test_classify -v
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "classify"))
import validate_decision_record as vdr  # noqa: E402
import vendor_probe as vp  # noqa: E402
import winget_manifest_lookup as wml  # noqa: E402

PROBE = os.path.join(ROOT, "tools", "classify", "vendor_probe.py")
LOOKUP = os.path.join(ROOT, "tools", "classify", "winget_manifest_lookup.py")


class ManifestParsing(unittest.TestCase):
    def test_root_fields_apply_to_every_installer(self):
        doc = {"InstallerType": "msix", "Scope": "machine",
               "Installers": [{"Architecture": "x64", "InstallerSha256": "A" * 64, "InstallerUrl": "https://x/a"},
                              {"Architecture": "arm64", "InstallerType": "exe", "InstallerUrl": "https://x/b"}]}
        inst = wml.merge_installers(doc)
        self.assertEqual(inst[0]["installerType"], "msix")
        self.assertEqual(inst[1]["installerType"], "exe")
        self.assertTrue(all(i["scope"] == "machine" for i in inst))
        s = wml.summarize(inst)
        self.assertEqual(s["machineScope"], "yes")
        self.assertFalse(s["sha256Present"])

    def test_undeclared_scope_is_unknown(self):
        s = wml.summarize(wml.merge_installers({"Installers": [{"InstallerType": "exe", "InstallerSha256": "B" * 64}]}))
        self.assertEqual(s["machineScope"], "unknown")

    def test_user_only(self):
        s = wml.summarize(wml.merge_installers({"Installers": [{"InstallerType": "exe", "Scope": "user"}]}))
        self.assertEqual(s["machineScope"], "no")

    def test_nested_installer_type_reported(self):
        s = wml.summarize(wml.merge_installers({"Installers": [{"InstallerType": "zip", "NestedInstallerType": "msi", "Scope": "machine"}]}))
        self.assertEqual(s["installerTypes"], ["zip/msi"])

    def test_package_dir(self):
        self.assertEqual(wml.package_dir("Microsoft.VisualStudio.2022.Community"), "manifests/m/Microsoft/VisualStudio/2022/Community")
        self.assertEqual(wml.package_dir("7zip.7zip"), "manifests/7/7zip/7zip")

    def test_version_order(self):
        self.assertEqual(sorted(["2.10", "2.9", "10.0", "2.10.1"], key=wml.version_key), ["2.9", "2.10", "2.10.1", "10.0"])


class VendorProbe(unittest.TestCase):
    def run_probe(self, doc, *extra):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(doc, f)
        try:
            p = subprocess.run([sys.executable, PROBE, "--file", f.name] + list(extra), capture_output=True, text=True)
            return p.returncode, json.loads(p.stdout)
        finally:
            os.unlink(f.name)

    def test_valid_response(self):
        code, r = self.run_probe({"releases": [{"version": "5.2.0", "url": "https://v.example/a.msi", "sha256": "a" * 64}]},
                                 "--version-path", "releases.0.version", "--url-path", "releases.0.url", "--sha256-path", "releases.0.sha256")
        self.assertEqual(code, 0)
        self.assertTrue(r["valid"])
        self.assertEqual(r["version"], "5.2.0")

    def test_rejects_non_strict_version(self):
        code, r = self.run_probe({"v": "5.2.0-beta"}, "--version-path", "v")
        self.assertEqual(code, 1)
        self.assertFalse(r["valid"])

    def test_rejects_http_download(self):
        code, r = self.run_probe({"v": "1.0", "u": "http://v.example/a.msi"}, "--version-path", "v", "--url-path", "u")
        self.assertFalse(r["valid"])

    def test_rejects_bad_hash(self):
        code, r = self.run_probe({"v": "1.0", "h": "xyz"}, "--version-path", "v", "--sha256-path", "h")
        self.assertFalse(r["valid"])

    def test_fingerprint_tracks_layout_not_values(self):
        a = vp.fingerprint({"releases": [{"version": "1.0", "url": "x"}]})
        b = vp.fingerprint({"releases": [{"version": "2.0", "url": "y"}, {"version": "3.0", "url": "z"}]})
        c = vp.fingerprint({"releases": [{"ver": "1.0", "url": "x"}]})
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_only_https_endpoints(self):
        with self.assertRaises(ValueError):
            vp.fetch("http://v.example/api", 5)


class DecisionRecord(unittest.TestCase):
    def base(self):
        return {"schemaVersion": "1.0.0", "packageId": "upd-x", "type": "app-update", "pattern": "B1", "subject": "X",
                "request": "r", "confidence": "high", "openQuestions": [], "evidence": [],
                "detection": {"displayNameLike": "X*", "mainExePaths": [], "versionSource": "FileVersion"},
                "install": {"expectedSigner": {"CN": "V", "O": "V"}, "sha256Published": False}}

    def test_valid(self):
        self.assertEqual(vdr.validate(self.base()), ([], False))

    def test_download_pattern_needs_signer(self):
        d = self.base()
        d["install"]["expectedSigner"] = {"CN": "V"}
        self.assertTrue(any("expectedSigner" in e for e in vdr.validate(d)[0]))

    def test_prefix_must_match_type(self):
        d = self.base()
        d["packageId"] = "cfg-x"
        self.assertTrue(any("must start with" in e for e in vdr.validate(d)[0]))

    def test_low_confidence_stops(self):
        d = self.base()
        d["confidence"] = "low"
        self.assertEqual(vdr.validate(d), ([], True))

    def test_open_questions_stop(self):
        d = self.base()
        d["openQuestions"] = ["which signer?"]
        self.assertTrue(vdr.validate(d)[1])

    def test_vuln_needs_advisory(self):
        d = {"schemaVersion": "1", "packageId": "vuln-x", "type": "vuln-remediation", "subject": "X", "request": "r",
             "confidence": "high", "openQuestions": [], "evidence": [], "vuln": {"cveIds": ["CVE-2026-1"], "fixKind": "version"}}
        self.assertTrue(any("advisoryUrls" in e for e in vdr.validate(d)[0]))


class LiveLookup(unittest.TestCase):
    """Network test against the real repository; skipped when unreachable."""

    def test_7zip(self):
        p = subprocess.run([sys.executable, LOOKUP, "7zip.7zip"], capture_output=True, text=True, timeout=900)
        if p.returncode == 1 and '"error"' in p.stdout:
            self.skipTest("winget-pkgs not reachable: " + p.stdout[:200])
        r = json.loads(p.stdout)
        self.assertTrue(r["found"])
        self.assertIn("machine", r["scopes"])
        self.assertTrue(r["manifestUrl"].startswith("https://github.com/microsoft/winget-pkgs/blob/"))


if __name__ == "__main__":
    unittest.main()
