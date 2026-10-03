"""Tests for tools/graph (Phase 5) against an in-memory fake Graph. No network, no sign-in.

Run: python3 -m unittest tools.tests.test_graph -v
"""
import base64
import datetime
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
import urllib.parse
from contextlib import redirect_stdout, redirect_stderr

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "graph", "lib"))
import graphcore as gc  # noqa: E402
import deploy_core as dc  # noqa: E402
import cli  # noqa: E402

LAB = "11111111-2222-3333-4444-555555555555"
OTHER = "99999999-8888-7777-6666-555555555555"
CLIENT = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PILOT = "a0000000-0000-0000-0000-000000000001"
BROAD = "b0000000-0000-0000-0000-000000000002"
FIXTURES = os.path.join(ROOT, "tools", "tests", "fixtures", "packages")
NOW = datetime.datetime(2026, 10, 3, 12, 0, 0, tzinfo=datetime.timezone.utc)


def read_bytes(p):
    with open(p, "rb") as f:
        return f.read()


class FakeAuth:
    def __init__(self, tenant, tid=None):
        self.tenant, self.tid = tenant, tid or tenant

    def token(self):
        gc.check_tid({"tid": self.tid}, self.tenant)
        return "fake-token"


class FakeGraph:
    """Implements only the endpoints the tools use, with the documented status codes."""

    def __init__(self):
        self.scripts, self.assignments, self.summary, self.states = {}, {}, {}, {}
        self.groups = {PILOT: {"id": PILOT, "displayName": "Lab Pilot", "groupTypes": [], "securityEnabled": True,
                               "mailEnabled": False, "members": {"user": 0, "device": 4, "group": 0}},
                       BROAD: {"id": BROAD, "displayName": "Lab All Devices", "groupTypes": ["DynamicMembership"],
                               "membershipRule": "(device.deviceOSType -eq \"Windows\")", "securityEnabled": True,
                               "mailEnabled": False, "members": {"user": 0, "device": 20, "group": 0}}}
        self.n, self.tick, self.throttle = 0, 0, 0
        self.content_on_get = True
        self.assign_merges = False
        self.log = []

    def _ts(self):
        self.tick += 1
        return "2026-10-03T12:%02d:00Z" % self.tick

    def request(self, method, url, headers, body):
        self.log.append((method, url))
        assert headers["Authorization"] == "Bearer fake-token"
        if self.throttle:
            self.throttle -= 1
            return 429, {"Retry-After": "1"}, b""
        u = urllib.parse.urlsplit(url)
        path, q = urllib.parse.unquote(u.path), urllib.parse.parse_qs(u.query)
        data = json.loads(body) if body else None
        js = lambda code, obj: (code, {"Content-Type": "application/json"}, json.dumps(obj).encode())  # noqa: E731
        m = re.fullmatch(r"/beta/deviceManagement/deviceHealthScripts(?:/([^/]+))?(?:/(\w+))?", path)
        if m:
            sid, sub = m.groups()
            if sid is None:
                if method == "GET":
                    return js(200, {"value": [dict(s) for s in self.scripts.values()]})
                self.n += 1
                sid = "5c000000-0000-0000-0000-%012d" % self.n
                s = dict(data, id=sid, lastModifiedDateTime=self._ts(), isGlobalScript=False)
                self.scripts[sid] = s
                self.assignments[sid] = []
                return js(201, s)
            if sid not in self.scripts:
                return js(404, {"error": {"code": "ResourceNotFound", "message": "not found"}})
            if sub is None and method == "GET":
                s = dict(self.scripts[sid])
                if not self.content_on_get:
                    s.pop("detectionScriptContent", None)
                    s.pop("remediationScriptContent", None)
                return js(200, s)
            if sub is None and method == "PATCH":
                self.scripts[sid].update(data)
                self.scripts[sid]["lastModifiedDateTime"] = self._ts()
                return js(200, self.scripts[sid])
            if sub == "assign" and method == "POST":
                new = [dict(a, id="as-%d" % i) for i, a in enumerate(data["deviceHealthScriptAssignments"])]
                self.assignments[sid] = (self.assignments[sid] + new) if self.assign_merges else new
                return 204, {}, b""
            if sub == "assignments":
                return js(200, {"value": self.assignments[sid]})
            if sub == "runSummary":
                return js(200, self.summary.get(sid, {}))
            if sub == "deviceRunStates":
                return js(200, {"value": self.states.get(sid, [])})
        m = re.fullmatch(r"/v1\.0/groups/([^/]+)/members/microsoft\.graph\.(\w+)/\$count", path)
        if m:
            assert headers.get("ConsistencyLevel") == "eventual"
            return 200, {"Content-Type": "text/plain"}, str(self.groups[m.group(1)]["members"][m.group(2)]).encode()
        m = re.fullmatch(r"/v1\.0/groups/([^/]+)", path)
        if m:
            g = self.groups.get(m.group(1))
            if not g:
                return js(404, {"error": {"code": "Request_ResourceNotFound", "message": "nope"}})
            return js(200, {k: v for k, v in g.items() if k != "members"})
        if path == "/v1.0/groups":
            assert headers.get("ConsistencyLevel") == "eventual"
            term = re.match(r'"displayName:(.*)"', q["$search"][0]).group(1).lower()
            hits = [{k: v for k, v in g.items() if k != "members"} for g in self.groups.values()
                    if term in g["displayName"].lower()]
            return js(200, {"value": hits})
        return js(400, {"error": {"code": "BadRequest", "message": "fake: unhandled %s %s" % (method, path)}})


class Base(unittest.TestCase):
    ptype = "app-update"
    fixture = "upd-example"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.pkg_dir = os.path.join(self.tmp, self.fixture)
        shutil.copytree(os.path.join(FIXTURES, self.fixture), self.pkg_dir)
        with open(os.path.join(self.pkg_dir, "gate-results.json"), "w") as f:
            json.dump({"packageId": self.fixture, "type": self.ptype}, f)
        self.cfg = {"tenant": {"allowlist": [LAB]}, "auth": {"clientId": CLIENT},
                    "deploymentDefaults": {"runAsAccount": "system", "runAs32Bit": False,
                                           "enforceSignatureCheck": False, "publisher": "Lab IT"},
                    "promotion": {"minPilotDevicesSucceeded": 3, "maxContractViolations": 0,
                                  "maxIssueReoccurredDevices": 0, "maxScriptErrorDevices": 0}}
        cfgp = os.path.join(self.tmp, "local.json")
        with open(cfgp, "w") as f:
            json.dump(self.cfg, f)
        os.environ["INTUNE_RMD_CONFIG"] = cfgp
        os.environ["INTUNE_RMD_OUT"] = os.path.join(self.tmp, "out")
        self.addCleanup(os.environ.pop, "INTUNE_RMD_CONFIG", None)
        self.addCleanup(os.environ.pop, "INTUNE_RMD_OUT", None)
        self.fake = FakeGraph()
        self.client = gc.GraphClient(FakeAuth(LAB), self.fake, sleep=lambda s: None)
        self.deliverable = True

    def status(self, pkg):
        hashes = {n: gc.sha256_bytes(read_bytes(os.path.join(pkg, n)))
                  for n in ("detect.ps1", "remediate.ps1") if os.path.exists(os.path.join(pkg, n))}
        if not self.deliverable:
            return {"deliverable": False, "blockers": ["gate4 is NOT_RUN"], "scriptSha256": hashes}
        return {"deliverable": True, "blockers": [], "scriptSha256": hashes}

    def gated_status(self):
        """Status frozen at 'gate time', so later edits count as drift."""
        frozen = self.status(self.pkg_dir)
        return lambda pkg: dict(frozen, deliverable=self.deliverable)

    def pkg(self):
        return dc.load_package(self.pkg_dir, self.status)

    def sched(self):
        return dc.build_schedule("daily", 1, "09:00", None, False)

    def deploy_plan(self, **kw):
        return dc.plan_deploy(self.client, self.cfg, LAB, self.pkg(), kw.pop("pilot", PILOT), kw.pop("broad", BROAD),
                              self.sched(), now=NOW, **kw)

    def apply(self, plan, path, confirm=None, now=None):
        return dc.apply_plan(self.client, self.cfg, LAB, path, plan["shortHash"] if confirm is None else confirm, self.status, now=now or NOW)


class TenantChecks(Base):
    def test_allowlist_required(self):
        with self.assertRaises(gc.GraphError):
            gc.require_tenant(self.cfg, OTHER)
        self.assertEqual(gc.require_tenant(self.cfg, LAB.upper()), LAB)

    def test_placeholder_allowlist_refuses(self):
        with self.assertRaises(gc.GraphError):
            gc.require_tenant({"tenant": {"allowlist": [gc.PLACEHOLDER_GUID]}}, gc.PLACEHOLDER_GUID)

    def test_token_from_other_tenant_refused_before_any_call(self):
        client = gc.GraphClient(FakeAuth(LAB, tid=OTHER), self.fake)
        with self.assertRaises(gc.GraphError):
            dc.describe_group(client, PILOT)
        self.assertEqual(self.fake.log, [])

    def test_missing_tid_refused(self):
        with self.assertRaises(gc.GraphError):
            gc.check_tid({}, LAB)

    def test_jwt_claims_decodes_payload(self):
        payload = base64.urlsafe_b64encode(json.dumps({"tid": LAB}).encode()).decode().rstrip("=")
        self.assertEqual(gc.jwt_claims("h." + payload + ".s")["tid"], LAB)

    def test_client_id_placeholder_refused(self):
        with self.assertRaises(gc.GraphError):
            gc.client_id({"auth": {"clientId": gc.PLACEHOLDER_GUID}})

    def test_cli_refuses_tenant_not_on_allowlist(self):
        sys.path.insert(0, os.path.join(ROOT, "tools", "graph", "read"))
        import groups
        cli.CLIENT_FACTORY = lambda cfg, tenant, scopes: self.fail("must not connect")
        self.addCleanup(setattr, cli, "CLIENT_FACTORY", None)
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = groups.main(["--tenant", OTHER, "search", "Lab"])
        self.assertEqual(code, 2)
        self.assertIn("allowlist", err.getvalue())


class ClientBehaviour(Base):
    def test_throttle_retried(self):
        self.fake.throttle = 2
        self.assertEqual(dc.describe_group(self.client, PILOT)["displayName"], "Lab Pilot")

    def test_error_message_redacts_ids(self):
        with self.assertRaises(gc.GraphError) as cm:
            dc.get_script(self.client, "5c000000-0000-0000-0000-000000000999")
        self.assertNotIn("5c000000", str(cm.exception))


class Groups(Base):
    def test_search_shows_candidates_without_choosing(self):
        r = dc.search_groups(self.client, "lab")
        self.assertEqual(len(r["candidates"]), 2)
        by = {c["id"]: c for c in r["candidates"]}
        self.assertEqual(by[PILOT]["membership"], "assigned")
        self.assertEqual(by[PILOT]["memberKind"], "devices")
        self.assertEqual(by[BROAD]["membership"], "dynamic")
        self.assertEqual(by[BROAD]["directMembers"]["devices"], 20)
        self.assertFalse(any(c["exactName"] for c in r["candidates"]))

    def test_group_id_must_be_guid(self):
        with self.assertRaises(gc.GraphError):
            dc.describe_group(self.client, "Lab Pilot")


class Schedules(Base):
    def test_shapes(self):
        self.assertEqual(dc.build_schedule("hourly", 4), {"@odata.type": "#microsoft.graph.deviceHealthScriptHourlySchedule", "interval": 4})
        d = dc.build_schedule("daily", 1, "09:30", None, True)
        self.assertEqual((d["time"], d["useUtc"]), ("09:30:00", True))
        o = dc.build_schedule("once", 1, "10:00", "2026-11-01")
        self.assertEqual(o["date"], "2026-11-01")

    def test_invalid(self):
        for args in (("weekly", 1), ("daily", 0, "09:00"), ("daily", 24, "09:00"), ("daily", 1, None), ("once", 1, "09:00", None)):
            with self.assertRaises(gc.GraphError):
                dc.build_schedule(*args)


class Package(Base):
    def test_not_deliverable_refused(self):
        self.deliverable = False
        with self.assertRaises(gc.GraphError) as cm:
            self.pkg()
        self.assertIn("not deliverable", str(cm.exception))

    def test_script_changed_after_gates_refused(self):
        status = self.gated_status()
        with open(os.path.join(self.pkg_dir, "detect.ps1"), "ab") as f:
            f.write(b"# edit\r\n")
        with self.assertRaises(gc.GraphError) as cm:
            dc.load_package(self.pkg_dir, status)
        self.assertIn("differs", str(cm.exception))

    def test_settings_hard_rules(self):
        for k, v in (("runAsAccount", "user"), ("runAs32Bit", True), ("enforceSignatureCheck", True), ("publisher", "<PUBLISHER_NAME>")):
            cfg = json.loads(json.dumps(self.cfg))
            cfg["deploymentDefaults"][k] = v
            with self.assertRaises(gc.GraphError):
                dc.script_body(self.pkg(), cfg)


class Deploy(Base):
    def test_same_group_needs_explicit_confirmation(self):
        with self.assertRaises(gc.GraphError) as cm:
            self.deploy_plan(broad=PILOT)
        self.assertIn("SAME_GROUP", str(cm.exception))
        self.assertEqual([m for m, _ in self.fake.log], [])
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.assertEqual(plan["rings"]["stage"], "single")
        self.assertTrue(plan["confirmations"]["sameGroup"])

    def test_confirm_same_group_with_different_groups_refused(self):
        with self.assertRaises(gc.GraphError):
            self.deploy_plan(confirm_same_group=True)

    def test_plan_makes_no_writes(self):
        self.deploy_plan()
        self.assertTrue(all(m == "GET" for m, _ in self.fake.log))
        self.assertEqual(self.fake.scripts, {})

    def test_create_assigns_pilot_only_and_verifies(self):
        plan, path = self.deploy_plan()
        self.assertEqual(plan["script"]["mode"], "create")
        self.assertEqual([a["target"]["groupId"] for a in plan["assignments"]], [PILOT])
        receipt, rpath = self.apply(plan, path)
        self.assertTrue(receipt["verified"], receipt)
        sid = receipt["scriptId"]
        s = self.fake.scripts[sid]
        self.assertEqual((s["runAsAccount"], s["runAs32Bit"], s["enforceSignatureCheck"]), ("system", False, False))
        self.assertEqual(base64.b64decode(s["detectionScriptContent"]), read_bytes(os.path.join(self.pkg_dir, "detect.ps1")))
        self.assertEqual([a["target"]["groupId"] for a in self.fake.assignments[sid]], [PILOT])
        self.assertTrue(self.fake.assignments[sid][0]["runRemediationScript"])
        state = dc.read_state("upd-example")
        self.assertEqual((state["scriptId"], state["stage"]), (sid, "pilot"))

    def test_wrong_or_short_confirmation_refused(self):
        plan, path = self.deploy_plan()
        for bad in ("0" * 12, plan["shortHash"][:8], "", plan["planHash"][::-1]):
            with self.assertRaises(gc.GraphError):
                self.apply(plan, path, confirm=bad)
        self.assertEqual(self.fake.scripts, {})

    def test_full_hash_accepted(self):
        plan, path = self.deploy_plan()
        receipt, _ = self.apply(plan, path, confirm=plan["planHash"])
        self.assertTrue(receipt["verified"])

    def test_tampered_plan_refused(self):
        plan, path = self.deploy_plan()
        d = json.loads(read_bytes(path))
        d["assignments"][0]["target"]["groupId"] = BROAD
        with open(path, "w") as f:
            json.dump(d, f)
        with self.assertRaises(gc.GraphError) as cm:
            self.apply(plan, path)
        self.assertIn("modified", str(cm.exception))
        self.assertEqual(self.fake.scripts, {})

    def test_expired_plan_refused(self):
        plan, path = self.deploy_plan()
        with self.assertRaises(gc.GraphError):
            self.apply(plan, path, now=NOW + datetime.timedelta(minutes=dc.PLAN_TTL_MINUTES + 1))

    def test_other_tenant_plan_refused(self):
        plan, path = self.deploy_plan()
        with self.assertRaises(gc.GraphError):
            dc.apply_plan(self.client, self.cfg, OTHER, path, plan["shortHash"], self.status, now=NOW)

    def test_replay_refused(self):
        plan, path = self.deploy_plan()
        self.apply(plan, path)
        with self.assertRaises(gc.GraphError) as cm:
            self.apply(plan, path)
        self.assertIn("already applied", str(cm.exception))

    def test_drift_since_plan_refused(self):
        plan, path = self.deploy_plan()
        self.fake.scripts["x"] = {"id": "x", "displayName": "upd-example"}
        with self.assertRaises(gc.GraphError) as cm:
            self.apply(plan, path)
        self.assertIn("appeared", str(cm.exception))

    def test_package_changed_since_plan_refused(self):
        plan, path = self.deploy_plan()
        with open(os.path.join(self.pkg_dir, "remediate.ps1"), "ab") as f:
            f.write(b"# edit\r\n")
        with self.assertRaises(gc.GraphError):
            self.apply(plan, path)
        self.assertEqual(self.fake.scripts, {})

    def test_duplicate_names_refused(self):
        for i in range(2):
            self.fake.scripts["d%d" % i] = {"id": "d%d" % i, "displayName": "upd-example"}
        with self.assertRaises(gc.GraphError):
            self.deploy_plan()

    def test_global_script_refused(self):
        self.fake.scripts["g"] = {"id": "g", "displayName": "upd-example", "isGlobalScript": True}
        with self.assertRaises(gc.GraphError):
            self.deploy_plan()

    def test_unverifiable_content_reported(self):
        self.fake.content_on_get = False
        plan, path = self.deploy_plan()
        receipt, _ = self.apply(plan, path)
        self.assertFalse(receipt["verified"])
        self.assertIsNone(dc.read_state("upd-example"))

    def test_assign_merge_semantics_detected(self):
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.apply(plan, path)
        self.fake.assign_merges = True
        with open(os.path.join(self.pkg_dir, "detect.ps1"), "ab") as f:
            f.write(b"# v2\r\n")
        plan2, path2 = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        receipt, _ = self.apply(plan2, path2)
        self.assertFalse(receipt["verified"])
        self.assertIn("live assignments differ from the plan", receipt["problems"])

    def test_receipt_written_on_failure(self):
        plan, path = self.deploy_plan()
        orig = self.fake.request

        def fail_assign(method, url, headers, body):
            if url.endswith("/assign"):
                return 500, {"Content-Type": "application/json"}, b'{"error":{"code":"InternalServerError","message":"x"}}'
            return orig(method, url, headers, body)
        self.fake.request = fail_assign
        with self.assertRaises(gc.GraphError):
            self.apply(plan, path)
        r = json.loads(read_bytes(os.path.join(os.environ["INTUNE_RMD_OUT"], "deploy", "upd-example", "receipt-%s.json" % plan["shortHash"])))
        self.assertEqual(r["steps"], ["created script"])
        self.assertTrue(r["scriptId"])
        self.assertFalse(r["verified"])


class Update(Base):
    def deploy_single(self):
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.apply(plan, path)
        return dc.read_state("upd-example")["scriptId"]

    def test_no_change_refused(self):
        self.deploy_single()
        with self.assertRaises(gc.GraphError) as cm:
            self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.assertIn("NO_CHANGE", str(cm.exception))

    def test_update_writes_diff_and_backup(self):
        sid = self.deploy_single()
        with open(os.path.join(self.pkg_dir, "detect.ps1"), "ab") as f:
            f.write(b"# v2\r\n")
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.assertEqual(plan["script"]["mode"], "update")
        self.assertIn("detectionScriptContent", plan["changes"])
        d = os.path.dirname(path)
        self.assertIn("+# v2", read_bytes(os.path.join(d, "diff-%s.txt" % plan["shortHash"])).decode())
        self.assertTrue(os.path.exists(os.path.join(d, "backup-%s" % plan["shortHash"], "detect.ps1")))
        receipt, _ = self.apply(plan, path)
        self.assertTrue(receipt["verified"])
        self.assertIn("updated script", receipt["steps"])
        self.assertTrue(base64.b64decode(self.fake.scripts[sid]["detectionScriptContent"]).endswith(b"# v2\r\n"))

    def test_update_reaching_other_groups_needs_confirmation(self):
        plan, path = self.deploy_plan()
        self.apply(plan, path)
        sid = dc.read_state("upd-example")["scriptId"]
        self.fake.assignments[sid].append(dict(dc.build_assignment(BROAD, self.sched(), True), id="x"))
        with open(os.path.join(self.pkg_dir, "detect.ps1"), "ab") as f:
            f.write(b"# v2\r\n")
        with self.assertRaises(gc.GraphError) as cm:
            self.deploy_plan()
        self.assertIn("UPDATE_REACHES_ALL", str(cm.exception))
        plan2, _ = self.deploy_plan(confirm_update_all=True)
        self.assertEqual(sorted(a["target"]["groupId"] for a in plan2["assignments"]), [PILOT, BROAD])

    def test_modified_in_portal_since_plan_refused(self):
        sid = self.deploy_single()
        with open(os.path.join(self.pkg_dir, "detect.ps1"), "ab") as f:
            f.write(b"# v2\r\n")
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.fake.scripts[sid]["lastModifiedDateTime"] = "2026-10-03T13:00:00Z"
        with self.assertRaises(gc.GraphError):
            self.apply(plan, path)


def state_line(pre, post=""):
    return {"preRemediationDetectionScriptOutput": pre, "postRemediationDetectionScriptOutput": post}


class Promote(Base):
    def deployed(self):
        plan, path = self.deploy_plan()
        self.apply(plan, path)
        return dc.read_state("upd-example")["scriptId"]

    def promote(self):
        return dc.plan_promote(self.client, self.cfg, LAB, self.pkg(), now=NOW)

    def test_criteria_met_adds_broad_keeps_pilot(self):
        sid = self.deployed()
        self.fake.summary[sid] = {"noIssueDetectedDeviceCount": 1, "issueRemediatedDeviceCount": 3}
        self.fake.states[sid] = [state_line("OUTDATED | 7-Zip 24.09 < 26.03", "UP_TO_DATE | 7-Zip 26.03"),
                                 state_line("UP_TO_DATE | 7-Zip 26.03")]
        plan, path, ev = self.promote()
        self.assertTrue(ev["pass"], ev)
        self.assertEqual(sorted(a["target"]["groupId"] for a in plan["assignments"]), [PILOT, BROAD])
        receipt, _ = self.apply(plan, path)
        self.assertTrue(receipt["verified"])
        self.assertEqual(dc.read_state("upd-example")["stage"], "broad")
        self.assertEqual(len([m for m, u in self.fake.log if m == "PATCH"]), 0)

    def test_too_few_successes(self):
        sid = self.deployed()
        self.fake.summary[sid] = {"noIssueDetectedDeviceCount": 1, "issueRemediatedDeviceCount": 1}
        plan, path, ev = self.promote()
        self.assertIsNone(plan)
        self.assertFalse(ev["pass"])

    def test_contract_violation_blocks(self):
        sid = self.deployed()
        self.fake.summary[sid] = {"noIssueDetectedDeviceCount": 5}
        self.fake.states[sid] = [state_line("Everything fine"), state_line("COMPLIANT | wrong type token")]
        plan, _, ev = self.promote()
        self.assertIsNone(plan)
        self.assertEqual([c["value"] for c in ev["checks"] if c["name"] == "contract violations"], [2])

    def test_reoccurred_and_errors_block(self):
        sid = self.deployed()
        for extra in ({"issueReoccurredDeviceCount": 1}, {"remediationScriptErrorDeviceCount": 1}):
            self.fake.summary[sid] = dict({"noIssueDetectedDeviceCount": 5}, **extra)
            self.assertIsNone(self.promote()[0])

    def test_single_ring_has_nothing_to_promote(self):
        plan, path = self.deploy_plan(broad=PILOT, confirm_same_group=True)
        self.apply(plan, path)
        with self.assertRaises(gc.GraphError):
            self.promote()

    def test_script_changed_since_pilot_refused(self):
        sid = self.deployed()
        self.fake.scripts[sid]["lastModifiedDateTime"] = "2026-10-03T14:00:00Z"
        with self.assertRaises(gc.GraphError):
            self.promote()

    def test_without_deploy_refused(self):
        with self.assertRaises(gc.GraphError):
            self.promote()


class Audit(Base):
    ptype = "audit"
    fixture = "aud-example"

    def test_audit_has_no_remediation_and_detect_only_assignment(self):
        plan, path = self.deploy_plan()
        receipt, _ = self.apply(plan, path)
        self.assertTrue(receipt["verified"], receipt)
        s = self.fake.scripts[receipt["scriptId"]]
        self.assertNotIn("remediationScriptContent", s)
        self.assertFalse(self.fake.assignments[receipt["scriptId"]][0]["runRemediationScript"])


class CliEndToEnd(Base):
    def test_plan_then_apply_via_cli(self):
        for d in ("plan", "write"):
            sys.path.insert(0, os.path.join(ROOT, "tools", "graph", d))
        import plan as plan_cli
        import apply as apply_cli
        cli.CLIENT_FACTORY = lambda cfg, tenant, scopes: self.client
        plan_cli.STATUS_FN = apply_cli.STATUS_FN = self.status
        self.addCleanup(setattr, cli, "CLIENT_FACTORY", None)
        out = io.StringIO()
        with redirect_stdout(out):
            code = plan_cli.main(["--tenant", LAB, "deploy", self.pkg_dir, "--pilot", PILOT, "--broad", BROAD,
                                  "--schedule", "daily", "--time", "08:00"])
        self.assertEqual(code, 0)
        s = json.loads(out.getvalue())
        out = io.StringIO()
        with redirect_stdout(out):
            code = apply_cli.main(["--tenant", LAB, "--plan", s["plan"], "--confirm", s["hash"]])
        self.assertEqual(code, 0, out.getvalue())
        self.assertTrue(json.loads(out.getvalue())["verified"])


if __name__ == "__main__":
    unittest.main()
