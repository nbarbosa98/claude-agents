# intune-rmd-scr-agent - project rules

Orchestrator for building, deploying and operating Intune Remediation scripts on a
Windows-only fleet. Lab tenant only.

- Decisions and their sources: `docs/decisions.md`. Draft script types: `docs/script-types.md`.
- Work in phases (`docs/phase-plan.md`). Stop for owner review at every phase boundary.
- Never guess an external fact (Graph endpoints, properties, permissions, winget fields,
  vendor URLs). Verify against an official source and cite it (repo path + commit, or URL).
  If you cannot verify it, mark it `UNVERIFIED` and say so.
- No secrets or tenant identifiers in the repo. Real values live in `config/local.json` (git-ignored).
- Never weaken a test, linter rule or the stdout contract to make a script pass. Changes to
  `contract/`, `tools/lint/` rules or the eval answer key need explicit owner approval.
- Every script is ASCII-only, including the project's own PowerShell tooling.
- No deployment or promotion without plan-hash approval by the user.
- Generators write `packages/<id>/src/`; `tools/compose/compose.py` builds the scripts and
  `tools/pipeline/pipeline.py` runs the gates. Never hand-edit composed scripts or gate results.
