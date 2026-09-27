---
name: deploy
description: Deploy a package to the pilot ring in the lab tenant after a guided setup and plan-hash approval. User-invoked only.
argument-hint: "<package-id>"
disable-model-invocation: true
---

Package: $ARGUMENTS

Status: the Graph deploy tooling (`tools/graph/`) is built in Phase 5. Until then, reply
that /deploy is not available yet and stop. Do not attempt any Graph call.

When implemented, the flow is (ADR-005, ADR-006, ADR-007):

1. Preconditions: every gate in `packages/<id>/gate-results.json` passed with an artifact.
2. Sign in with the user's own credentials (delegated).
3. Ask the user for the pilot group and the broad group names. Search Entra for each and
   show candidates (display name, object id, assigned or dynamic, member count, users or
   devices). The user picks; never pick between several matches.
4. If pilot and broad are the same group: stop and ask the user to confirm explicitly that
   they want to deploy to that whole group now, with no pilot stage. Record the answer in
   the plan.
5. Confirm schedule, run as SYSTEM, 64-bit, signature check, create vs update (with a diff
   against the deployed content).
6. Print the plan and its hash. Apply only when the user types that exact hash.
