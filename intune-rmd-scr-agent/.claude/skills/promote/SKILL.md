---
name: promote
description: Promote a package from the pilot ring to the broad ring when the promotion criteria are met, after plan-hash approval. User-invoked only.
argument-hint: "<package-id>"
disable-model-invocation: true
---

Package: $ARGUMENTS

Status: built in Phase 5. Until then, reply that /promote is not available yet and stop.

When implemented: check the promotion criteria from `config/local.json` (absolute counts:
minimum pilot devices succeeded, zero contract violations, no "recurred" beyond the
configured cycles), print the plan and its hash, and apply only when the user types the
hash.
