#!/usr/bin/env python3
"""Build a deploy or promote plan (reads Graph, writes only out/deploy/<package>/). ADR-006, ADR-007.

  plan.py --tenant <guid> deploy packages/<id> --pilot <group-id> --broad <group-id>
          --schedule once|hourly|daily [--interval N] [--time HH:MM] [--date YYYY-MM-DD] [--utc]
          [--confirm-same-group] [--confirm-update-all]
  plan.py --tenant <guid> promote packages/<id> [--schedule ... to differ from the pilot's]

Prints the plan summary and its hash. Nothing is changed in the tenant; apply with
tools/graph/write/apply.py after the user types the hash.
Exit codes: 0 plan written; 1 promotion criteria not met; 2 refused or failed.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cli  # noqa: E402
import deploy_core as dc  # noqa: E402
import graphcore as gc  # noqa: E402

# Pluggable for tests (pipeline status needs pwsh-built artifacts).
STATUS_FN = None


def add_schedule(sp, required):
    sp.add_argument("--schedule", choices=sorted(dc.SCHEDULE_TYPES), required=required)
    sp.add_argument("--interval", type=int, default=1)
    sp.add_argument("--time")
    sp.add_argument("--date")
    sp.add_argument("--utc", action="store_true")


def summary(plan, path):
    r = plan["rings"]
    lines = {"plan": str(path), "kind": plan["kind"], "package": plan["package"]["id"], "mode": plan["script"]["mode"],
             "stage": r["stage"], "pilot": {k: r["pilot"].get(k) for k in ("displayName", "membership", "directMembers")},
             "broad": {k: r["broad"].get(k) for k in ("displayName", "membership", "directMembers")},
             "sameGroup": r["sameGroup"], "changes": sorted(plan["changes"]), "assignments": dc.norm_assignments(plan["assignments"]),
             "warnings": plan["warnings"], "expiresAt": plan["expiresAt"], "hash": plan["shortHash"],
             "next": "Show this to the user. Apply only after the user types the hash: "
                     "tools/graph/write/apply.py --tenant <tenant> --plan <plan> --confirm <hash>"}
    if plan.get("evaluation"):
        lines["evaluation"] = plan["evaluation"]["checks"]
    return lines


def main(argv=None):
    p = cli.parser("Plan a deploy or promotion (no tenant changes)")
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("deploy")
    d.add_argument("package")
    d.add_argument("--pilot", required=True)
    d.add_argument("--broad", required=True)
    d.add_argument("--confirm-same-group", action="store_true")
    d.add_argument("--confirm-update-all", action="store_true")
    add_schedule(d, True)
    pr = sub.add_parser("promote")
    pr.add_argument("package")
    add_schedule(pr, False)
    args = p.parse_args(argv)

    def go():
        cfg, tenant, client = cli.connect(args, gc.SCOPES_READ)
        pkg = dc.load_package(args.package, STATUS_FN)
        sched = dc.build_schedule(args.schedule, args.interval, args.time, args.date, args.utc) if args.schedule else None
        if args.cmd == "deploy":
            plan, path = dc.plan_deploy(client, cfg, tenant, pkg, args.pilot, args.broad, sched,
                                        args.confirm_same_group, args.confirm_update_all)
            return gc.emit(summary(plan, path))
        plan, path, ev = dc.plan_promote(client, cfg, tenant, pkg, sched)
        if plan is None:
            return gc.emit({"promotion": "criteria not met", "evaluation": ev}, 1)
        return gc.emit(summary(plan, path))
    return cli.run(go)


if __name__ == "__main__":
    sys.exit(main())
