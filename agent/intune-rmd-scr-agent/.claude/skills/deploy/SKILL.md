---
name: deploy
description: Deploy a package to the pilot ring in the lab tenant after a guided setup and plan-hash approval. User-invoked only.
argument-hint: "<package-id>"
disable-model-invocation: true
---

Package: $ARGUMENTS

Deterministic tools do every check; you run them, show their output, and ask the user.
Never call Graph any other way. Design: docs/decisions.md ADR-005, ADR-006, ADR-007, ADR-035.
`<tenant>` is the lab tenant GUID the user gives you for this session (see tools/graph/README.md).

1. **Preconditions.** Run `python3 tools/pipeline/pipeline.py status packages/<id>`. If it is not
   deliverable, show the blockers and stop. Gate 4 must have passed; do not work around it.
2. **Pilot group.** Ask the user for the pilot group name. Run
   `python3 tools/graph/read/groups.py --tenant <tenant> search "<name>"` and show every candidate:
   display name, object id, assigned or dynamic (with the rule), direct members (users, devices,
   nested groups). The user picks one by object id. Never pick for them, even with one exact match.
   Zero candidates: ask for another name. `more: true`: say the list was cut and ask to narrow it.
3. **Broad group.** Same as step 2 for the broad ring.
4. **Same group.** If the user picked the same object id for pilot and broad, stop and ask, in
   these words or close: "Pilot and broad are the same group. This deploys to the whole group now,
   with no pilot stage. Do you want that?" Only an explicit yes allows `--confirm-same-group`.
   Anything else: go back to step 2.
5. **Settings.** Confirm with the user, one at a time:
   - schedule: `once` (date and time), `hourly` (every N hours), or `daily` (every N days at a time);
     N from 1 to 23; local time or UTC.
   - fixed by the hard rules, shown for confirmation only: run as SYSTEM, 64-bit PowerShell,
     signature check off (scripts are not signed). If the user wants other values, stop: the tools
     refuse them.
6. **Plan.** Run
   `python3 tools/graph/plan/plan.py --tenant <tenant> deploy packages/<id> --pilot <pilot-id> --broad <broad-id> --schedule <kind> [--interval N] [--time HH:MM] [--date YYYY-MM-DD] [--utc] [--confirm-same-group]`.
   - `SAME_GROUP`: go back to step 4.
   - `UPDATE_REACHES_ALL`: the script already exists and is assigned beyond the pilot, so new content
     reaches those devices at once. Show this to the user. Only on an explicit yes, re-plan with
     `--confirm-update-all`.
   - `NO_CHANGE`: tell the user nothing needs deploying and stop.
   - Update mode: show the settings changes and the script diff file (`diff-<hash>.txt`).
     The previous content is backed up in `backup-<hash>/`.
7. **Approval.** Show the plan summary: mode, groups, assignments, schedule, warnings, expiry, and
   the 12-character hash. Ask the user to type the hash to apply. Do not type, repeat, or suggest
   the hash on the user's behalf in the apply command until the user has typed it in chat. A reply
   such as "yes" or "go" is not approval. The plan expires after 60 minutes.
8. **Apply.** `python3 tools/graph/write/apply.py --tenant <tenant> --plan <plan path> --confirm <hash the user typed>`.
   Claude Code will also ask for permission (the `ask` rule on tools/graph/write/).
   - Exit 0: applied and verified. Report the steps and the receipt path.
   - Exit 1: applied but not verified. Report each problem word for word; do not call it deployed.
   - Exit 2: refused or failed. Report the error. If the receipt lists steps (for example a script
     was created but assignment failed), say exactly which, and that nothing was rolled back.
9. **Next.** Tell the user that `/promote <id>` checks the pilot results later. Nothing is
   promoted automatically.
