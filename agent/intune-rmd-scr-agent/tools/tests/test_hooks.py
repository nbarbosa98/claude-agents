"""Unit tests for .claude/hooks/tenant-guard.py and readonly-guard.py.

Run: python3 -m unittest discover -s tools/tests -v
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TENANT_GUARD = os.path.join(ROOT, ".claude", "hooks", "tenant-guard.py")
RO_GUARD = os.path.join(ROOT, ".claude", "hooks", "readonly-guard.py")
LAB = "11111111-2222-3333-4444-555555555555"
OTHER = "99999999-8888-7777-6666-555555555555"


def run(hook, command, project_dir, args=(), tool="Bash"):
    payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool,
                          "tool_input": {"command": command}, "cwd": project_dir})
    env = dict(os.environ, CLAUDE_PROJECT_DIR=project_dir)
    p = subprocess.run([sys.executable, hook] + list(args), input=payload, text=True,
                       capture_output=True, env=env)
    return p.returncode, p.stderr


class TenantGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        os.makedirs(os.path.join(self.dir, "config"))

    def tearDown(self):
        self.tmp.cleanup()

    def cfg(self, allow):
        with open(os.path.join(self.dir, "config", "local.json"), "w") as f:
            json.dump({"tenant": {"allowlist": allow}}, f)

    def test_unrelated_command_allowed(self):
        self.assertEqual(run(TENANT_GUARD, "git status", self.dir)[0], 0)

    def test_write_allowlisted_tenant_allowed(self):
        self.cfg([LAB])
        cmd = "pwsh -NoProfile -File tools/graph/write/Deploy-Remediation.ps1 -TenantId %s -Plan x" % LAB
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 0)

    def test_write_other_tenant_denied(self):
        self.cfg([LAB])
        cmd = "pwsh -File tools/graph/write/Deploy-Remediation.ps1 -TenantId %s" % OTHER
        code, err = run(TENANT_GUARD, cmd, self.dir)
        self.assertEqual(code, 2)
        self.assertIn("not on allowlist", err)

    def test_write_mixed_tenants_denied(self):
        self.cfg([LAB])
        cmd = "pwsh -File tools/graph/write/X.ps1 -TenantId %s --tenant %s" % (LAB, OTHER)
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 2)

    def test_write_without_tenant_denied(self):
        self.cfg([LAB])
        self.assertEqual(run(TENANT_GUARD, "pwsh -File tools/graph/write/X.ps1", self.dir)[0], 2)

    def test_write_without_config_denied(self):
        cmd = "pwsh -File tools/graph/write/X.ps1 -TenantId %s" % LAB
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 2)

    def test_placeholder_allowlist_denied(self):
        self.cfg(["00000000-0000-0000-0000-000000000000"])
        cmd = "pwsh -File tools/graph/write/X.ps1 -TenantId 00000000-0000-0000-0000-000000000000"
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 2)

    def test_raw_rest_denied(self):
        self.cfg([LAB])
        cmd = "curl -X POST https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts"
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 2)

    def test_sdk_write_cmdlet_denied(self):
        self.cfg([LAB])
        cmd = "pwsh -c New-MgBetaDeviceManagementDeviceHealthScript -BodyParameter $b"
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 2)

    def test_read_tool_allowed(self):
        cmd = "pwsh -File tools/graph/read/Get-RunStates.ps1 -Package upd-7zip"
        self.assertEqual(run(TENANT_GUARD, cmd, self.dir)[0], 0)

    def test_bad_input_fails_closed(self):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.dir)
        p = subprocess.run([sys.executable, TENANT_GUARD], input="not json", text=True,
                           capture_output=True, env=env)
        self.assertEqual(p.returncode, 2)


class ReadonlyGuard(unittest.TestCase):
    def test_ops_read_tool_allowed(self):
        cmd = "pwsh -NoProfile -File tools/graph/read/Get-RunStates.ps1 -Package upd-7zip"
        self.assertEqual(run(RO_GUARD, cmd, ROOT, ["ops"])[0], 0)

    def test_ops_write_tool_denied(self):
        cmd = "pwsh -File tools/graph/write/Deploy-Remediation.ps1"
        self.assertEqual(run(RO_GUARD, cmd, ROOT, ["ops"])[0], 2)

    def test_ops_chaining_denied(self):
        cmd = "pwsh -File tools/graph/read/Get-RunStates.ps1; rm -rf out"
        self.assertEqual(run(RO_GUARD, cmd, ROOT, ["ops"])[0], 2)

    def test_ops_substitution_denied(self):
        cmd = "python3 tools/graph/read/x.py $(cat config/local.json)"
        self.assertEqual(run(RO_GUARD, cmd, ROOT, ["ops"])[0], 2)

    def test_ops_path_traversal_denied(self):
        cmd = "python3 tools/graph/read/../write/x.py"
        self.assertEqual(run(RO_GUARD, cmd, ROOT, ["ops"])[0], 2)

    def test_classifier_profile(self):
        self.assertEqual(run(RO_GUARD, "python3 tools/classify/winget_manifest_lookup.py 7zip.7zip", ROOT, ["classifier"])[0], 0)
        self.assertEqual(run(RO_GUARD, "python3 tools/graph/read/x.py", ROOT, ["classifier"])[0], 2)

    def test_unknown_profile_fails_closed(self):
        self.assertEqual(run(RO_GUARD, "python3 tools/classify/x.py", ROOT, ["nope"])[0], 2)

    def test_non_bash_tool_ignored(self):
        self.assertEqual(run(RO_GUARD, "", ROOT, ["ops"], tool="Read")[0], 0)


if __name__ == "__main__":
    unittest.main()
