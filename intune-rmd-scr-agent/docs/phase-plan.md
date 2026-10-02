# Phase plan (revised after Phase 0)

Each phase ends with a report (what was built, how it was verified, what is open;
facts, assumptions and inferences kept apart) and stops for owner approval.

| Phase | Scope | Runs where | Depends on |
|---|---|---|---|
| 0 | Decisions, prerequisites, scaffold (DONE) | Cloud | - |
| 1 | (DONE) Knowledge base from scratch: `contract/stdout.json`, skill + references per type (verified sources), agent files (orchestrator, 5 generators, classifier, reviewer, ops-agent), `.claude/settings.json` (`agent`, `ask` rules), tenant-guard hook | Cloud | Approval of `docs/script-types.md` |
| 2 | (DONE) Gate 1 linter (+ PSScriptAnalyzer wrapper), Gate 2 Pester harness and per-type test matrices, classifier tools (winget manifest lookup, vendor probe) | Cloud; PSScriptAnalyzer on Mac | Phase 1 |
| 3 | (IN REVIEW: built, not yet run on a VM) Gate 4 VM harness (SYSTEM scheduled task, 64-bit, snapshot revert, negative scenarios); measure platform timeout and PowerShell host version | Mac + Azure VM | Owner's Azure VM |
| 4 | (IN REVIEW) Orchestration loop `/new-remediation`: route, classify, generate, Gates 1-4, repair loop (max 3), metrics | Cloud + Mac | Phases 1-3 |
| 5 | Delegated sign-in, Entra group search, guided setup (schedule, context, rings), plan-hash `/deploy` and `/promote`, same-group confirmation | Mac | Phase 4; verified scopes |
| 6 | `ops-agent`: list all remediations, run states, success rates, failure clustering, troubleshooting | Mac | Phase 5 |
| 7 | Optional: Defender intake (feeds vuln-remediation-agent), `/drift` | Mac | Phase 6; MDE in lab |
| 8 | Evals: fixtures across all five types (owner labels the answer key), metrics, regression diffs | Cloud + Mac | Phase 4 |
| 9 | Public README, architecture diagram, safety model, limitations, sanitizer | Cloud | All |
