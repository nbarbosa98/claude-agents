"""Deterministic core of /deploy and /promote (ADR-006, ADR-007, ADR-035).

Planning reads live state and writes a plan file under out/deploy/<package>/; applying re-checks
everything the plan relied on and only then writes to Graph. All Graph facts are cited in
graphcore.py and docs/decisions.md ADR-035 ([GD] = microsoft-graph-docs-contrib @4ad99fd).
"""
import base64
import datetime
import difflib
import json
import re
import sys
import urllib.parse
from pathlib import Path

import graphcore as gc
from graphcore import GraphError

sys.path.insert(0, str(gc.ROOT / "tools" / "pipeline"))

PLAN_SCHEMA = 1
PLAN_TTL_MINUTES = 60
SHORT = 12
SCRIPTS = gc.GRAPH_BETA + "/deviceManagement/deviceHealthScripts"
GROUPS = gc.GRAPH_V1 + "/groups"
# [GD] beta/resources/intune-devices-devicehealthscript*schedule.md: interval "Valid values 1 to 23".
SCHEDULE_TYPES = {"once": "deviceHealthScriptRunOnceSchedule", "hourly": "deviceHealthScriptHourlySchedule",
                  "daily": "deviceHealthScriptDailySchedule"}
STATUS_LINE = re.compile(r"^([A-Z][A-Z_]+) \| ")
GROUP_SELECT = "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled"


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


# ---------------------------------------------------------------- package

def pipeline_status(pkg_dir):
    from pipeline import Pipeline
    return Pipeline(pkg_dir).status()[1]


def readme_summary(pkg):
    try:
        text = (pkg / "README.md").read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return ""
    m = re.search(r"^## Summary\s*\n+(.*?)(?:\n\s*\n|\n## )", text, re.S | re.M)
    return re.sub(r"\s+", " ", m.group(1)).strip()[:500] if m else ""


def load_package(pkg_dir, status_fn=None):
    """The package must be deliverable (all four gates passed, with artifacts) and its scripts must
    be byte-identical to what the gates saw."""
    pkg = Path(pkg_dir).resolve()
    st = (status_fn or pipeline_status)(pkg)
    if not st.get("deliverable"):
        raise GraphError("package is not deliverable: " + "; ".join(st.get("blockers") or ["unknown"]))
    contract = json.loads((gc.ROOT / "contract" / "stdout.json").read_text(encoding="ascii"))
    results = json.loads((pkg / "gate-results.json").read_text(encoding="ascii"))
    ptype = results["type"]
    roles = contract["scriptsByType"][ptype]
    scripts, sha = {}, {}
    for role in roles:
        name = role + ".ps1"
        b = (pkg / name).read_bytes()
        if any(c > 127 for c in b):
            raise GraphError("%s is not ASCII-only" % name)
        h = gc.sha256_bytes(b)
        if st.get("scriptSha256", {}).get(name) != h:
            raise GraphError("%s differs from the bytes the gates passed" % name)
        scripts[role], sha[role] = b, h
    return {"id": pkg.name, "dir": str(pkg.relative_to(gc.ROOT)) if pkg.is_relative_to(gc.ROOT) else str(pkg),
            "type": ptype, "roles": roles, "scripts": scripts, "sha256": sha, "summary": readme_summary(pkg),
            "contract": contract}


# ---------------------------------------------------------------- shapes

def build_schedule(kind, interval=1, time_s=None, date_s=None, use_utc=False):
    if kind not in SCHEDULE_TYPES:
        raise GraphError("schedule must be one of: once, hourly, daily")
    if not isinstance(interval, int) or not 1 <= interval <= 23:
        raise GraphError("interval must be an integer from 1 to 23")
    s = {"@odata.type": "#microsoft.graph." + SCHEDULE_TYPES[kind], "interval": interval}
    if kind == "hourly":
        return s
    if not time_s or not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", time_s):
        raise GraphError("--time HH:MM is required for once and daily schedules")
    s.update({"time": time_s + ":00", "useUtc": bool(use_utc)})
    if kind == "once":
        if not date_s or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_s):
            raise GraphError("--date YYYY-MM-DD is required for a once schedule")
        s["date"] = date_s
    return s


def build_assignment(group_id, schedule, run_remediation):
    # [GD] beta/resources/intune-devices-devicehealthscriptassignment.md, intune-shared-groupassignmenttarget.md
    return {"@odata.type": "#microsoft.graph.deviceHealthScriptAssignment",
            "target": {"@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": group_id},
            "runRemediationScript": bool(run_remediation), "runSchedule": schedule}


def norm_schedule(s):
    if not s:
        return None
    out = {"type": (s.get("@odata.type") or "").lstrip("#"), "interval": s.get("interval")}
    if s.get("time"):
        out["time"] = str(s["time"])[:8]
    if "useUtc" in s:
        out["useUtc"] = bool(s["useUtc"])
    if s.get("date"):
        out["date"] = str(s["date"])[:10]
    return out


def norm_assignments(items):
    """Order-independent comparable form of an assignment set."""
    out = []
    for a in items or []:
        t = a.get("target") or {}
        out.append({"targetType": (t.get("@odata.type") or "").lstrip("#"), "groupId": (t.get("groupId") or "").lower(),
                    "runRemediationScript": bool(a.get("runRemediationScript")), "schedule": norm_schedule(a.get("runSchedule"))})
    return sorted(out, key=gc.canonical)


def rebuild_assignment(a):
    """Re-creates an existing assignment in request form (drops the read-only id)."""
    t = a.get("target") or {}
    if (t.get("@odata.type") or "").lstrip("#") != "microsoft.graph.groupAssignmentTarget":
        raise GraphError("existing assignment targets %s; only group targets are supported" % (t.get("@odata.type") or "unknown"))
    s = dict(a.get("runSchedule") or {})
    if s.get("@odata.type") and not s["@odata.type"].startswith("#"):
        s["@odata.type"] = "#" + s["@odata.type"]
    return build_assignment(t["groupId"], s, a.get("runRemediationScript"))


def script_body(pkg, cfg):
    d = cfg.get("deploymentDefaults") or {}
    # Hard rules: SYSTEM, 64-bit (HR-09/HR-11 platform.md). Scripts are not signed, so the
    # signature check stays off; changing that needs a signing pipeline (not built).
    if (d.get("runAsAccount") or "system") != "system":
        raise GraphError("deploymentDefaults.runAsAccount must be 'system'")
    if d.get("runAs32Bit"):
        raise GraphError("deploymentDefaults.runAs32Bit must be false (64-bit PowerShell)")
    if d.get("enforceSignatureCheck"):
        raise GraphError("enforceSignatureCheck=true needs signed scripts; there is no signing pipeline")
    pub = (d.get("publisher") or "").strip()
    if not pub or "<" in pub:
        raise GraphError("deploymentDefaults.publisher in config/local.json is missing or a placeholder")
    content = gc.sha256_bytes(b"".join(pkg["scripts"][r] for r in pkg["roles"]))
    body = {"@odata.type": "#microsoft.graph.deviceHealthScript", "displayName": pkg["id"],
            "description": (pkg["summary"] + " Managed by intune-rmd-scr-agent.").strip(),
            "publisher": pub, "version": content[:SHORT], "runAsAccount": "system",
            "enforceSignatureCheck": False, "runAs32Bit": False,
            "detectionScriptContent": base64.b64encode(pkg["scripts"]["detect"]).decode("ascii")}
    if "remediate" in pkg["scripts"]:
        body["remediationScriptContent"] = base64.b64encode(pkg["scripts"]["remediate"]).decode("ascii")
    return body


# ---------------------------------------------------------------- reads

def describe_group(client, gid):
    if not gc.GUID_RE.match(gid or ""):
        raise GraphError("group id must be a GUID (pick one from the search results)")
    g = client.get("%s/%s?$select=%s" % (GROUPS, gid, GROUP_SELECT))
    counts = {}
    # [GD] v1.0/api/group-list-members.md: OData cast and /$count with ConsistencyLevel: eventual.
    # Direct members only; nested groups are counted, not expanded.
    for kind in ("user", "device", "group"):
        counts[kind + "s"] = client.count("%s/%s/members/microsoft.graph.%s/$count" % (GROUPS, gid, kind))
    dyn = "DynamicMembership" in (g.get("groupTypes") or [])
    return {"id": g["id"].lower(), "displayName": g.get("displayName"), "membership": "dynamic" if dyn else "assigned",
            "membershipRule": g.get("membershipRule") if dyn else None,
            "securityEnabled": g.get("securityEnabled"), "mailEnabled": g.get("mailEnabled"),
            "directMembers": counts,
            "memberKind": "devices" if counts["devices"] and not counts["users"] else
                          "users" if counts["users"] and not counts["devices"] else
                          "mixed" if counts["users"] and counts["devices"] else "empty-or-nested"}


def search_groups(client, name, top=10):
    """[GD] v1.0/api/group-list.md: $search on displayName needs ConsistencyLevel: eventual."""
    term = name.replace('"', "").replace("\\", "").strip()
    if not term:
        raise GraphError("group name is empty")
    q = urllib.parse.urlencode({"$search": '"displayName:%s"' % term, "$select": GROUP_SELECT,
                                "$top": str(top), "$count": "true"}, quote_via=urllib.parse.quote)
    page = client.get("%s?%s" % (GROUPS, q), headers={"ConsistencyLevel": "eventual"})
    cands = [describe_group(client, g["id"]) for g in page.get("value", [])[:top]]
    for c in cands:
        c["exactName"] = (c["displayName"] or "").lower() == term.lower()
    return {"query": term, "candidates": cands, "more": bool(page.get("@odata.nextLink"))}


def find_scripts_by_name(client, name):
    # The list API documents no OData query options, so filter client-side.
    return [s for s in client.get_all(SCRIPTS) if s.get("displayName") == name]


def get_script(client, sid):
    return client.get("%s/%s" % (SCRIPTS, sid))


def get_assignments(client, sid):
    return client.get_all("%s/%s/assignments" % (SCRIPTS, sid))


def decode_content(v):
    if not v:
        return None
    try:
        return base64.b64decode(v)
    except ValueError:
        return None


def content_changes(existing, pkg):
    """Settings and script differences between the deployed script and the package."""
    changes, diffs = {}, []
    for role, key in (("detect", "detectionScriptContent"), ("remediate", "remediationScriptContent")):
        old = decode_content(existing.get(key))
        new = pkg["scripts"].get(role)
        old_h = gc.sha256_bytes(old) if old is not None else None
        new_h = gc.sha256_bytes(new) if new is not None else None
        if old_h != new_h:
            changes[key] = {"fromSha256": old_h, "toSha256": new_h}
            a = (old or b"").decode("ascii", "replace").splitlines()
            b = (new or b"").decode("ascii", "replace").splitlines()
            diffs += list(difflib.unified_diff(a, b, "deployed/%s.ps1" % role, "package/%s.ps1" % role, lineterm=""))
    return changes, "\n".join(diffs)


def settings_changes(existing, body):
    out = {}
    for k in ("description", "publisher", "version", "runAsAccount", "enforceSignatureCheck", "runAs32Bit"):
        if existing.get(k) != body.get(k):
            out[k] = {"from": existing.get(k), "to": body.get(k)}
    return out


# ---------------------------------------------------------------- plan files

def deploy_dir(pkg_id):
    d = gc.out_root() / "deploy" / pkg_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def finalize_plan(plan, extra_files=None):
    h = gc.plan_hash(plan)
    plan["planHash"], plan["shortHash"] = h, h[:SHORT]
    d = deploy_dir(plan["package"]["id"])
    path = d / ("plan-%s.json" % h[:SHORT])
    path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="ascii")
    for name, text in (extra_files or {}).items():
        (d / name.format(short=h[:SHORT])).write_text(text, encoding="ascii", errors="replace")
    return path


def load_plan(path):
    plan = json.loads(Path(path).read_text(encoding="ascii"))
    if plan.get("schema") != PLAN_SCHEMA:
        raise GraphError("unknown plan schema")
    if plan.get("planHash") != gc.plan_hash(plan):
        raise GraphError("plan file was modified after it was created; re-plan")
    return plan


def read_state(pkg_id):
    p = gc.out_root() / "deploy" / pkg_id / "state.json"
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="ascii"))


def write_state(pkg_id, state):
    (deploy_dir(pkg_id) / "state.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="ascii")


# ---------------------------------------------------------------- deploy

def plan_deploy(client, cfg, tenant, pkg, pilot_id, broad_id, schedule, confirm_same_group=False,
                confirm_update_all=False, now=None):
    now = now or utcnow()
    pilot_id, broad_id = (pilot_id or "").lower(), (broad_id or "").lower()
    same = pilot_id == broad_id
    if same and not confirm_same_group:
        raise GraphError("SAME_GROUP: pilot and broad are the same group. Ask the user whether they really want to "
                         "deploy to that whole group now with no pilot stage; only on an explicit yes, re-plan with "
                         "--confirm-same-group")
    if confirm_same_group and not same:
        raise GraphError("--confirm-same-group is only valid when pilot and broad are the same group")
    pilot = describe_group(client, pilot_id)
    broad = pilot if same else describe_group(client, broad_id)
    stage = broad if same else pilot
    body = script_body(pkg, cfg)
    run_rem = "remediate" in pkg["scripts"]
    want = build_assignment(stage["id"], schedule, run_rem)
    warnings, extra = [], {}
    matches = find_scripts_by_name(client, pkg["id"])
    if len(matches) > 1:
        raise GraphError("%d remediations are named %s; resolve the duplicates in the portal first" % (len(matches), pkg["id"]))
    if matches:
        existing = get_script(client, matches[0]["id"])
        if existing.get("isGlobalScript"):
            raise GraphError("the existing script is a Microsoft proprietary (global) script; refusing")
        current = get_assignments(client, existing["id"])
        changes, diff_text = content_changes(existing, pkg)
        changes.update(settings_changes(existing, body))
        others = [a for a in norm_assignments(current) if a["groupId"] != stage["id"]]
        content_changed = any(k in changes for k in ("detectionScriptContent", "remediationScriptContent"))
        if others and content_changed and not confirm_update_all:
            raise GraphError("UPDATE_REACHES_ALL: the script is already assigned to %d other group(s); changing its "
                             "content reaches those devices at once, with no pilot stage. Ask the user; only on an "
                             "explicit yes, re-plan with --confirm-update-all" % len(others))
        kept = [rebuild_assignment(a) for a in current
                if ((a.get("target") or {}).get("groupId") or "").lower() != stage["id"]]
        assignments = kept + [want]
        script = {"mode": "update", "scriptId": existing["id"]}
        before = {"scriptId": existing["id"], "lastModifiedDateTime": existing.get("lastModifiedDateTime"),
                  "assignments": norm_assignments(current)}
        if diff_text:
            extra["diff-{short}.txt"] = diff_text + "\n"
        backup = {"detect.ps1": decode_content(existing.get("detectionScriptContent")),
                  "remediate.ps1": decode_content(existing.get("remediationScriptContent"))}
        if not changes and norm_assignments(assignments) == before["assignments"]:
            raise GraphError("NO_CHANGE: the deployed script and assignments already match the package and plan")
    else:
        changes, assignments, backup = {}, [want], {}
        script = {"mode": "create", "scriptId": None}
        before = {"scriptId": None, "nameMatches": 0}
    if stage["membership"] == "dynamic":
        warnings.append("stage group is dynamic; membership can change after the plan")
    if stage["memberKind"] in ("empty-or-nested",):
        warnings.append("stage group has no direct user or device members")
    plan = {"schema": PLAN_SCHEMA, "kind": "deploy", "createdAt": iso(now),
            "expiresAt": iso(now + datetime.timedelta(minutes=PLAN_TTL_MINUTES)), "tenantId": tenant,
            "package": {"id": pkg["id"], "dir": pkg["dir"], "type": pkg["type"], "scriptSha256": pkg["sha256"]},
            "script": dict(script, settings={k: v for k, v in body.items() if not k.endswith("ScriptContent")}),
            "changes": changes,
            "rings": {"pilot": pilot, "broad": broad, "sameGroup": same, "stage": "single" if same else "pilot"},
            "confirmations": {"sameGroup": bool(confirm_same_group), "updateReachesAll": bool(confirm_update_all)},
            "assignments": assignments, "before": before, "warnings": warnings}
    path = finalize_plan(plan, extra)
    if backup:
        bdir = deploy_dir(pkg["id"]) / ("backup-%s" % plan["shortHash"])
        bdir.mkdir(exist_ok=True)
        for n, b in backup.items():
            if b is not None:
                (bdir / n).write_bytes(b)
    return plan, path


# ---------------------------------------------------------------- promote

def detect_tokens(contract, ptype):
    return {t["token"] for t in contract["tokens"]
            if ptype in t["types"] and any(e["script"] == "detect" for e in t["emits"])}


def contract_violations(states, contract, ptype):
    allowed = detect_tokens(contract, ptype)
    bad = []
    for s in states:
        for f in ("preRemediationDetectionScriptOutput", "postRemediationDetectionScriptOutput"):
            v = (s.get(f) or "").strip()
            if not v:
                continue
            first = v.splitlines()[0]
            m = STATUS_LINE.match(first)
            if not m or m.group(1) not in allowed:
                bad.append({"field": f, "line": first[:120]})
    return bad


def evaluate_promotion(summary, states, contract, ptype, crit):
    """Absolute-count criteria from config 'promotion' (ADR-007, ADR-035).
    [GD] beta/resources/intune-devices-devicehealthscriptrunsummary.md for the counters."""
    s = summary or {}
    succeeded = int(s.get("noIssueDetectedDeviceCount") or 0) + int(s.get("issueRemediatedDeviceCount") or 0)
    reoccurred = int(s.get("issueReoccurredDeviceCount") or 0)
    errors = int(s.get("detectionScriptErrorDeviceCount") or 0) + int(s.get("remediationScriptErrorDeviceCount") or 0)
    violations = contract_violations(states, contract, ptype)
    need = {"minPilotDevicesSucceeded": int(crit.get("minPilotDevicesSucceeded", 3)),
            "maxContractViolations": int(crit.get("maxContractViolations", 0)),
            "maxIssueReoccurredDevices": int(crit.get("maxIssueReoccurredDevices", 0)),
            "maxScriptErrorDevices": int(crit.get("maxScriptErrorDevices", 0))}
    checks = [
        {"name": "pilot devices succeeded", "value": succeeded, "rule": ">= %d" % need["minPilotDevicesSucceeded"],
         "pass": succeeded >= need["minPilotDevicesSucceeded"]},
        {"name": "contract violations", "value": len(violations), "rule": "<= %d" % need["maxContractViolations"],
         "pass": len(violations) <= need["maxContractViolations"]},
        {"name": "issue reoccurred devices", "value": reoccurred, "rule": "<= %d" % need["maxIssueReoccurredDevices"],
         "pass": reoccurred <= need["maxIssueReoccurredDevices"]},
        {"name": "script error devices", "value": errors, "rule": "<= %d" % need["maxScriptErrorDevices"],
         "pass": errors <= need["maxScriptErrorDevices"]},
    ]
    return {"pass": all(c["pass"] for c in checks), "checks": checks, "violations": violations[:20],
            "pending": int(s.get("detectionScriptPendingDeviceCount") or 0),
            "lastScriptRunDateTime": s.get("lastScriptRunDateTime")}


def plan_promote(client, cfg, tenant, pkg, schedule=None, now=None):
    now = now or utcnow()
    state = read_state(pkg["id"])
    if not state or not state.get("scriptId"):
        raise GraphError("no applied deploy recorded for this package in out/deploy/; run /deploy first")
    if state["tenantId"] != tenant:
        raise GraphError("the recorded deploy belongs to a different tenant")
    if state["rings"]["sameGroup"]:
        raise GraphError("this package was deployed to a single ring; there is nothing to promote")
    pilot, broad = state["rings"]["pilot"], state["rings"]["broad"]
    existing = get_script(client, state["scriptId"])
    if existing.get("lastModifiedDateTime") != state.get("lastModifiedDateTime"):
        raise GraphError("the script changed since the pilot deploy; the pilot results no longer apply")
    if state["package"]["scriptSha256"] != pkg["sha256"]:
        raise GraphError("the package scripts changed since the pilot deploy; deploy the new version to the pilot first")
    current = get_assignments(client, state["scriptId"])
    groups = {a["groupId"] for a in norm_assignments(current)}
    if broad["id"] in groups:
        raise GraphError("the broad group is already assigned")
    if groups != {pilot["id"]}:
        raise GraphError("live assignments are not exactly the pilot group; resolve that before promoting")
    summary = client.get("%s/%s/runSummary" % (SCRIPTS, state["scriptId"]))
    states = client.get_all("%s/%s/deviceRunStates" % (SCRIPTS, state["scriptId"]))
    crit = cfg.get("promotion") or {}
    ev = evaluate_promotion(summary, states, pkg["contract"], pkg["type"], crit)
    if not ev["pass"]:
        return None, None, ev
    pilot_a = [rebuild_assignment(a) for a in current]
    sched = schedule or pilot_a[0]["runSchedule"]
    assignments = pilot_a + [build_assignment(broad["id"], sched, "remediate" in pkg["scripts"])]
    broad_now = describe_group(client, broad["id"])
    plan = {"schema": PLAN_SCHEMA, "kind": "promote", "createdAt": iso(now),
            "expiresAt": iso(now + datetime.timedelta(minutes=PLAN_TTL_MINUTES)), "tenantId": tenant,
            "package": {"id": pkg["id"], "dir": pkg["dir"], "type": pkg["type"], "scriptSha256": pkg["sha256"]},
            "script": {"mode": "assign-only", "scriptId": state["scriptId"]}, "changes": {},
            "rings": {"pilot": pilot, "broad": broad_now, "sameGroup": False, "stage": "broad"},
            "confirmations": {}, "evaluation": ev, "assignments": assignments,
            "before": {"scriptId": state["scriptId"], "lastModifiedDateTime": existing.get("lastModifiedDateTime"),
                       "assignments": norm_assignments(current)}, "warnings": []}
    path = finalize_plan(plan)
    return plan, path, ev


# ---------------------------------------------------------------- apply

def apply_plan(client, cfg, tenant, plan_path, confirm, status_fn=None, now=None):
    now = now or utcnow()
    plan = load_plan(plan_path)
    if not confirm or len(confirm) < SHORT or not plan["planHash"].startswith(confirm.lower()):
        raise GraphError("the confirmation does not match this plan's hash; nothing was changed")
    if plan["tenantId"] != tenant:
        raise GraphError("the plan was made for a different tenant; nothing was changed")
    if now > parse_iso(plan["expiresAt"]):
        raise GraphError("the plan expired at %s; re-plan" % plan["expiresAt"])
    d = deploy_dir(plan["package"]["id"])
    receipt_path = d / ("receipt-%s.json" % plan["shortHash"])
    if receipt_path.exists():
        raise GraphError("this plan was already applied (%s); re-plan for a new change" % receipt_path.name)
    pkg = load_package(gc.ROOT / plan["package"]["dir"], status_fn)
    if pkg["sha256"] != plan["package"]["scriptSha256"]:
        raise GraphError("package scripts changed since the plan; re-plan")
    # Drift: the live state must still be what the plan was computed from.
    before = plan["before"]
    if before["scriptId"] is None:
        if find_scripts_by_name(client, pkg["id"]):
            raise GraphError("a script named %s appeared since the plan; re-plan" % pkg["id"])
    else:
        live = get_script(client, before["scriptId"])
        if live.get("lastModifiedDateTime") != before["lastModifiedDateTime"]:
            raise GraphError("the script was modified since the plan; re-plan")
        if norm_assignments(get_assignments(client, before["scriptId"])) != before["assignments"]:
            raise GraphError("assignments changed since the plan; re-plan")
    receipt = {"planHash": plan["planHash"], "kind": plan["kind"], "startedAt": iso(now), "steps": [], "verified": False}
    sid = before["scriptId"]
    try:
        if plan["kind"] == "deploy":
            body = script_body(pkg, cfg)
            if plan["script"]["mode"] == "create":
                created = client.call("POST", SCRIPTS, body=body, expect=(201,))
                sid = created["id"]
                receipt["steps"].append("created script")
            elif plan["changes"]:
                client.call("PATCH", "%s/%s" % (SCRIPTS, sid), body=body, expect=(200, 204))
                receipt["steps"].append("updated script")
        # [GD] beta/api/intune-devices-devicehealthscript-assign.md: POST .../assign, 204 No Content.
        # Whether assign replaces or merges is not documented (UNVERIFIED), so the full intended set is
        # sent and the result is verified below.
        client.call("POST", "%s/%s/assign" % (SCRIPTS, sid),
                    body={"deviceHealthScriptAssignments": plan["assignments"]}, expect=(200, 204))
        receipt["steps"].append("assigned")
        live = get_script(client, sid)
        got = norm_assignments(get_assignments(client, sid))
        problems = []
        if got != norm_assignments(plan["assignments"]):
            problems.append("live assignments differ from the plan")
        for role, key in (("detect", "detectionScriptContent"), ("remediate", "remediationScriptContent")):
            if role not in pkg["scripts"]:
                continue
            b = decode_content(live.get(key))
            if b is None:
                problems.append("%s content not returned by GET; content not verified" % role)
            elif gc.sha256_bytes(b) != pkg["sha256"][role]:
                problems.append("%s content differs from the package" % role)
        receipt["verified"] = not problems
        receipt["problems"] = problems
        receipt["scriptId"] = sid
        receipt["lastModifiedDateTime"] = live.get("lastModifiedDateTime")
    except GraphError as e:
        receipt["error"] = str(e)
        receipt["scriptId"] = sid
        raise
    finally:
        receipt["finishedAt"] = iso(utcnow())
        receipt["calls"] = [[m, gc.redact(u), s] for m, u, s in client.calls]
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="ascii")
    if receipt["verified"]:
        state = read_state(pkg["id"]) or {}
        state.update({"tenantId": plan["tenantId"], "scriptId": sid, "lastModifiedDateTime": receipt["lastModifiedDateTime"],
                      "package": plan["package"], "rings": {k: plan["rings"][k] for k in ("pilot", "broad", "sameGroup")},
                      "stage": plan["rings"]["stage"], "lastPlan": plan["planHash"], "appliedAt": receipt["finishedAt"]})
        write_state(pkg["id"], state)
    return receipt, receipt_path
