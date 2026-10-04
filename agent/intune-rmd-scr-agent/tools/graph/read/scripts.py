#!/usr/bin/env python3
"""Read Intune Remediations (deviceHealthScripts) - read-only. Phase 6 builds ops on top.

  scripts.py --tenant <guid> list                    id, name, publisher, version, modified
  scripts.py --tenant <guid> get <script-id>         settings and content hashes (no content)
  scripts.py --tenant <guid> assignments <script-id>
  scripts.py --tenant <guid> summary <script-id>     runSummary counters
  scripts.py --tenant <guid> states <script-id>      per-device states, outputs truncated

Exit codes: 0 ok, 2 refused or failed.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cli  # noqa: E402
import deploy_core as dc  # noqa: E402
import graphcore as gc  # noqa: E402

LIST_FIELDS = ("id", "displayName", "publisher", "version", "lastModifiedDateTime", "isGlobalScript", "runAsAccount", "runAs32Bit")
STATE_FIELDS = ("detectionState", "remediationState", "lastStateUpdateDateTime", "preRemediationDetectionScriptOutput",
                "postRemediationDetectionScriptOutput", "remediationScriptError")


def main(argv=None):
    p = cli.parser("Read Intune Remediations (read-only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    for c in ("get", "assignments", "summary", "states"):
        sub.add_parser(c).add_argument("script_id")
    args = p.parse_args(argv)

    def go():
        _, _, client = cli.connect(args, gc.SCOPES_READ)
        if args.cmd == "list":
            return gc.emit([{k: s.get(k) for k in LIST_FIELDS} for s in client.get_all(dc.SCRIPTS)])
        sid = args.script_id
        if not gc.GUID_RE.match(sid):
            raise gc.GraphError("script id must be a GUID")
        if args.cmd == "get":
            s = dc.get_script(client, sid)
            out = {k: v for k, v in s.items() if not k.endswith("ScriptContent")}
            for k in ("detectionScriptContent", "remediationScriptContent"):
                b = dc.decode_content(s.get(k))
                out[k + "Sha256"] = gc.sha256_bytes(b) if b is not None else None
            return gc.emit(out)
        if args.cmd == "assignments":
            return gc.emit(dc.get_assignments(client, sid))
        if args.cmd == "summary":
            return gc.emit(client.get("%s/%s/runSummary" % (dc.SCRIPTS, sid)))
        states = client.get_all("%s/%s/deviceRunStates" % (dc.SCRIPTS, sid))
        return gc.emit([{k: (str(s.get(k))[:200] if s.get(k) is not None else None) for k in STATE_FIELDS} for s in states])
    return cli.run(go)


if __name__ == "__main__":
    sys.exit(main())
