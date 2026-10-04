# Reviewer checklist (Gate 3)

The reviewer receives only: the scripts, `contract/stdout.json`, this skill's references,
the decision record, and the Gate 1 and Gate 2 results. Never the generator's reasoning.

## Perspectives

1. **Compliance**: every applicable hard rule (HR-01 to HR-21); every status line uses a
   token the contract allows for this type and script, with the right exit code;
   README sections present.
2. **Reliability**: every path ends in `Exit-WithCode`; bounded waits; installed-version
   routine identical in detect and remediate; post-check before success; behaviour when
   the network, winget or the vendor endpoint is unavailable.
3. **Security**: secure staging; installer trust before execution; no downloads over
   plain HTTP; no secrets; no personal data in output; config-change guardrails; no
   privilege or ACL changes beyond the staging dir.
4. **Completeness**: evidence in the decision record supports every constant; no
   `UNVERIFIED` fact used silently; README rollback is concrete; known failure modes listed.

## Report format

One line per check, grouped by perspective:

```
[PASS] HR-08 Test-InstallerTrust called before msiexec (remediate.ps1:84)
[FAIL] HR-13 REMEDIATED emitted without post-check (remediate.ps1:97)
[WARN] FM-04 VERSION_SOURCE=DisplayVersion; catalog uses 4-part versions, confirm format
```

Then a verdict line: `VERDICT: PASS` or `VERDICT: FAIL (<n> FAIL, <m> WARN)`.
Any `[FAIL]` fails Gate 3. For `general` packages, any `[WARN]` also fails Gate 3.
Every `[FAIL]` and `[WARN]` cites file and line, and the rule or failure-mode ID.
