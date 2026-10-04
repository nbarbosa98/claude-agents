"""Argument and sign-in boilerplate shared by the tools/graph CLIs."""
import argparse
import sys

import graphcore as gc

# Tests replace this with a factory returning a client bound to a fake Graph.
CLIENT_FACTORY = None


def parser(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--tenant", required=True, help="lab tenant GUID; must be on the allowlist in config/local.json")
    return p


def connect(args, scopes):
    cfg = gc.load_config()
    tenant = gc.require_tenant(cfg, args.tenant)
    if CLIENT_FACTORY is not None:
        return cfg, tenant, CLIENT_FACTORY(cfg, tenant, scopes)
    return cfg, tenant, gc.GraphClient(gc.MsalAuth(cfg, tenant, scopes))


def run(main):
    try:
        return main()
    except gc.GraphError as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
