---
name: promote
description: Promote a package from the pilot ring to the broad ring when the promotion criteria are met, after plan-hash approval. User-invoked only.
argument-hint: "<package-id>"
disable-model-invocation: true
---

Package: $ARGUMENTS

Design: docs/decisions.md ADR-007, ADR-035. `<tenant>` is the lab tenant GUID for this session.

1. Run `python3 tools/graph/plan/plan.py --tenant <tenant> promote packages/<id>`.
   The tool refuses when: there is no applied pilot deploy recorded in `out/deploy/<id>/`; the
   deploy was single-ring; the script or the package changed since the pilot deploy; the live
   assignments are not exactly the pilot group; the broad group is already assigned.
2. Exit 1 means the criteria are not met. Show every check (name, value, rule) and any contract
   violations, and stop. Do not suggest lowering the thresholds. If devices are still pending,
   say so: the user may wait and run /promote again.
3. Exit 0: show the evaluation, the broad group (display name, membership, direct members), the
   schedule (the pilot's unless the user asked for another; pass `--schedule ...` then), and the
   12-character hash. Ask the user to type the hash.
4. Only after the user types the hash: `python3 tools/graph/write/apply.py --tenant <tenant> --plan <plan path> --confirm <hash the user typed>`.
   Report the result exactly as /deploy step 8 says.

Criteria (absolute counts, `promotion` in config/local.json), from the script's run summary while
only the pilot group is assigned:
- devices succeeded (no issue detected + issue remediated) >= `minPilotDevicesSucceeded`
- detection outputs that break the stdout contract <= `maxContractViolations`
- devices where the issue reoccurred <= `maxIssueReoccurredDevices`
- devices with a detection or remediation script error <= `maxScriptErrorDevices`
