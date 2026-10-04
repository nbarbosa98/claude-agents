---
name: ops
description: Read-only view of Intune Remediations in the lab tenant - list packages, read scripts, success rates, run-state triage and troubleshooting.
argument-hint: "[package-id | all]"
---

Scope: $ARGUMENTS

Delegate to the `ops-agent` subagent with the scope above. It is read-only. Its Graph
read tools arrive in Phase 6; until then it reports that and stops. Any fix it proposes
goes through /new-remediation and /deploy, never directly.
