# Graph tools (Phase 5)

Delegated Microsoft Graph access with the operator's own account, for the lab tenant only.
Design and sources: `docs/decisions.md` ADR-005, ADR-006, ADR-007, ADR-035. Runs on the
operator's Mac; the cloud build container cannot reach Graph.

| Path | Writes to the tenant | Who may run it |
|---|---|---|
| `read/groups.py` | no | orchestrator, ops-agent |
| `read/scripts.py` | no | orchestrator, ops-agent |
| `plan/plan.py` | no (writes `out/deploy/<id>/` only) | orchestrator (/deploy, /promote) |
| `write/apply.py` | yes | orchestrator, after the user types the plan hash; Claude Code asks for permission |

## One-time setup on the Mac

1. `python3 -m pip install -r tools/requirements.txt` (msal 1.39.0, msal-extensions 1.3.1).
2. In the lab tenant, register a public-client app: platform "Mobile and desktop
   applications", redirect URI `http://localhost`. Add the delegated Microsoft Graph
   permissions `DeviceManagementScripts.ReadWrite.All`, `DeviceManagementScripts.Read.All` and
   `GroupMember.Read.All`, and grant consent for the lab tenant.
3. Copy `config/example.json` to `config/local.json` (git-ignored) and fill in the tenant
   allowlist, `auth.clientId` and `deploymentDefaults.publisher`.
4. Your account also needs an Intune role with the Device configurations permissions
   (ADR-005) and Entra rights to read group members.

Sign-in opens a browser on first use. With `auth.tokenCache: "keychain"` the token cache is
encrypted in the macOS Keychain; `"memory"` signs in on every run.

## Commands

```
python3 tools/graph/read/groups.py  --tenant <guid> search "<name>"
python3 tools/graph/read/groups.py  --tenant <guid> get <group-id>
python3 tools/graph/read/scripts.py --tenant <guid> list | get <id> | assignments <id> | summary <id> | states <id>
python3 tools/graph/plan/plan.py    --tenant <guid> deploy packages/<id> --pilot <gid> --broad <gid> --schedule daily --time 09:00 [--interval N] [--utc]
python3 tools/graph/plan/plan.py    --tenant <guid> promote packages/<id>
python3 tools/graph/write/apply.py  --tenant <guid> --plan out/deploy/<id>/plan-<hash>.json --confirm <hash>
```

Exit codes: 0 ok; 1 plan: promotion criteria not met, apply: applied but not verified; 2 refused
or failed (nothing was changed unless the receipt lists steps).

## What every tool checks (layer 5 of ADR-020)

- `--tenant` is a GUID on the allowlist in `config/local.json` (the hook checks this too).
- The ID token's `tid` equals `--tenant`, before the first Graph call.
- Errors never print object ids (`{id}` in URLs).

`apply.py` also refuses when: the confirmation is not the plan's hash (12+ hex characters);
the plan file was edited; the plan expired (60 minutes); the plan was already applied; the
package is not deliverable or its scripts differ from the bytes the gates passed; the live
script or assignments changed since planning. After writing it re-reads the script and the
assignments, then writes `receipt-<hash>.json`, verified or not.

## Tests

`python3 -m unittest tools.tests.test_graph -v` runs the planner and apply against an
in-memory fake Graph (no network, no msal needed). Known gaps are in `docs/limitations.md`
(L11 to L13) and the UNVERIFIED list in ADR-035.
