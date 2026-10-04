---
name: new-remediation
description: Build a new Intune Remediation package from a request (app name, winget id, CVE, setting, audit question). Routes to the right generator and runs the gate pipeline.
argument-hint: "<request, e.g. 'keep 7-Zip up to date' or 'CVE-2024-12345'>"
---

Request: $ARGUMENTS

Run the orchestrator workflow. `P` = `python3 tools/pipeline/pipeline.py`.

1. Route the request (ask the user if the type is ambiguous; refuse OS cumulative updates
   and Microsoft 365 Apps with the reason).
2. Propose a package id with the type prefix and confirm it with the user.
3. app-update / vuln-remediation: run `classifier`; stop on low confidence or open questions.
   Other types: the generator writes the decision record from your brief.
4. Run the generator. It writes `packages/<id>/src/`, `README.md`, `gate4.json`.
5. `P start packages/<id>` then `P gates packages/<id>`.
6. If Gates 1-2 passed (Gate 2 may be PASS_PENDING_WINDOWS): run `reviewer` (fresh context,
   package path only), save its report to `out/<id>/review-iter-<n>.txt`,
   `P review packages/<id> out/<id>/review-iter-<n>.txt`.
7. If Gate 3 passed: `P gate4 packages/<id>` (lab VM) or `P gate4 packages/<id> --backend skip`.
8. Any failure: `P evidence packages/<id>` -> generator repairs with only that evidence ->
   `P repair packages/<id> --cites <ids>` -> back to step 5. Exit 4 = budget exhausted: stop and
   report diagnosis, ranked root causes, confirming evidence.
9. `P status packages/<id>`; `P finish packages/<id> --outcome <delivered|stopped|budget-exhausted>`.
10. Deliver the package summary. A package is deliverable to /deploy only when `P status`
    says so (all four gates PASS with artifacts; PASS_PENDING_* and NOT_RUN never are).
