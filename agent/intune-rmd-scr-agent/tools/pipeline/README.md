# Pipeline driver (/new-remediation)

`tools/pipeline/pipeline.py` runs the deterministic part of the loop; the orchestrator agent
decides and delegates (ADR-032). Typical run (`P` = `python3 tools/pipeline/pipeline.py`):

```
P start  packages/upd-7zip                 # validates decision record and src/
P gates  packages/upd-7zip                 # compose, Gate 1, Gate 2 (stops at first failure)
P review packages/upd-7zip out/upd-7zip/review-iter-0.txt   # Gate 3 from the reviewer report
P gate4  packages/upd-7zip [--backend azure|local|skip]
P evidence packages/upd-7zip               # failing evidence E1..En for the generator
P repair packages/upd-7zip --cites E1,E2   # next iteration; max 3 repairs (exit 4 after)
P status packages/upd-7zip                 # deliverable? blockers?
P finish packages/upd-7zip --outcome delivered|stopped|budget-exhausted
```

State: `packages/<id>/gate-results.json` (iterations, gate status, artifact paths, cites).
Artifacts: `out/<id>/iter-<n>/` (git-ignored); on delivery, the final ones are copied to
`packages/<id>/evidence/`. Metrics: `out/metrics.jsonl`. `INTUNE_RMD_OUT` overrides `out/`
(tests). Exit codes: 0 ok, 1 gate failed or not deliverable, 3 usage or input error,
4 repair budget exhausted.
