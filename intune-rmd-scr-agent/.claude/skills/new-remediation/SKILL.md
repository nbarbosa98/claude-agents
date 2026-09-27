---
name: new-remediation
description: Build a new Intune Remediation package from a request (app name, winget id, CVE, setting, audit question). Routes to the right generator and runs the gate pipeline.
argument-hint: "<request, e.g. 'keep 7-Zip up to date' or 'CVE-2024-12345'>"
---

Request: $ARGUMENTS

Run the orchestrator workflow from your agent instructions:

1. Route the request (ask the user if the type is ambiguous; refuse OS cumulative updates
   and Microsoft 365 Apps with the reason).
2. Propose a package id with the type prefix and confirm it with the user.
3. app-update / vuln-remediation: run `classifier`; stop on low confidence or open questions.
4. Run the generator with the brief.
5. Gates 1-4 in order, repair loop at most 3 iterations. Any gate without tooling is
   recorded `NOT_RUN` in `gate-results.json` (Phase status: Gate 1/2 arrive in Phase 2,
   Gate 4 in Phase 3). A package with a `NOT_RUN` gate is not deliverable for /deploy.
6. Deliver the package summary.
