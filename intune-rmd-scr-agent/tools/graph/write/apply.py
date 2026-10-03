#!/usr/bin/env python3
"""Apply a deploy or promote plan to the lab tenant. The only Graph write path (ADR-020, ADR-035).

  apply.py --tenant <guid> --plan out/deploy/<id>/plan-<hash>.json --confirm <hash typed by the user>

Refuses unless: tenant on the allowlist (here and in the tenant-guard hook); token tid equals the
tenant; the plan file is unmodified and unexpired; --confirm matches its hash (12+ hex chars);
the package is still deliverable with the same script bytes; live state is unchanged since the
plan. Writes a receipt to out/deploy/<id>/receipt-<hash>.json, verified or not.
Exit codes: 0 applied and verified; 1 applied but verification found problems; 2 refused or failed.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cli  # noqa: E402
import deploy_core as dc  # noqa: E402
import graphcore as gc  # noqa: E402

STATUS_FN = None


def main(argv=None):
    p = cli.parser("Apply a plan (writes to the lab tenant)")
    p.add_argument("--plan", required=True)
    p.add_argument("--confirm", required=True, help="the plan hash, as typed by the user")
    args = p.parse_args(argv)

    def go():
        cfg, tenant, client = cli.connect(args, gc.SCOPES_WRITE)
        receipt, path = dc.apply_plan(client, cfg, tenant, args.plan, args.confirm, STATUS_FN)
        out = {"receipt": str(path), "verified": receipt["verified"], "steps": receipt["steps"],
               "problems": receipt.get("problems", [])}
        return gc.emit(out, 0 if receipt["verified"] else 1)
    return cli.run(go)


if __name__ == "__main__":
    sys.exit(main())
