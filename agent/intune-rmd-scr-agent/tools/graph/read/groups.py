#!/usr/bin/env python3
"""Entra group search for /deploy setup (read-only, ADR-006).

  groups.py --tenant <guid> search "<name>"   candidates with membership type and member counts
  groups.py --tenant <guid> get <group-id>

Shows candidates; never picks one. The user chooses by object id.
Exit codes: 0 ok, 2 refused or failed.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cli  # noqa: E402
import deploy_core as dc  # noqa: E402
import graphcore as gc  # noqa: E402


def main(argv=None):
    p = cli.parser("Search Entra groups (read-only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("name")
    g = sub.add_parser("get")
    g.add_argument("group_id")
    args = p.parse_args(argv)

    def go():
        _, _, client = cli.connect(args, gc.SCOPES_READ)
        if args.cmd == "search":
            return gc.emit(dc.search_groups(client, args.name))
        return gc.emit(dc.describe_group(client, args.group_id))
    return cli.run(go)


if __name__ == "__main__":
    sys.exit(main())
