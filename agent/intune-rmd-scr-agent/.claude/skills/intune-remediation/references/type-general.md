# Type: general

For requests that fit no other type. Package id prefix: `gen-`.

- If the request fits app-update, vuln-remediation, config-change or audit, hand back to
  the orchestrator with the suggested type instead of generating.
- Uses the shared skeleton, helpers and contract. Tokens: `COMPLIANT`, `NONCOMPLIANT`,
  `REMEDIATED`, `PENDING_REBOOT`, `NOT_APPLICABLE`, `NOT_DETERMINED`, `FAILED`, `ERROR`.
  No new tokens without a contract change approved by the owner.
- README `## Rollback` is mandatory and must be concrete (what to run, what it restores).
- The reviewer treats a general package as highest risk: every `WARN` is blocking.
