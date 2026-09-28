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
5. Gates 1-4 in order, repair loop at most 3 iterations:
   - Gate 1: `python3 tools/lint/lint.py packages/<id> --out out/<id>/gate1.json`
   - Gate 2: `pwsh -NoProfile -File tools/pester/Invoke-Gate2.ps1 -PackagePath packages/<id> -OutFile out/<id>/gate2.json`
   - Gate 3: the `reviewer` subagent.
   - Gate 4: not built yet (Phase 3): record `NOT_RUN`.
   `PASS_PENDING_PSSA`, `PASS_PENDING_WINDOWS` and `NOT_RUN` are recorded as such and are not
   deliverable for /deploy.
6. Deliver the package summary.
