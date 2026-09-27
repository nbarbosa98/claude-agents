# Known failure modes

Used by the generators (to avoid them), the reviewer (to check for them) and ops-agent
(to map run-state clusters to causes). "Signature" is what shows up in the status line or
log.

| ID | Failure mode | Signature | Cause class | Prevention / response |
|---|---|---|---|---|
| FM-01 | winget not found under SYSTEM | `NOT_DETERMINED ... winget not found` | Environment | App Installer missing or not provisioned for the machine; unsupported path (ADR-016) |
| FM-02 | winget found but fails to start under SYSTEM | `FAILED ... winget exit <code>` with no catalog output | Environment | Unsupported context (ADR-016); check App Installer version; fallback pattern B1 |
| FM-03 | Catalog version unavailable | `NOT_DETERMINED ... catalog version unavailable` | Environment | Network, source agreement, proxy; retried next schedule |
| FM-04 | Installed version format differs from catalog format | Endless `OUTDATED` after `REMEDIATED`-looking runs ("Recurred") | Script defect | Wrong `VERSION_SOURCE` in decision record; fix and regenerate |
| FM-05 | Per-user install only | `SKIPPED_USER_SCOPE` | Expected | D2: out of scope for v1 |
| FM-06 | App running, update staged | `STAGED` | Expected | Resolves at app restart; never force-close (HR-20) |
| FM-07 | Installer signature or hash mismatch | `FAILED ... signature status ...` / `SHA256 mismatch` / `signer mismatch` | Security or vendor change | Investigate before anything else; vendor cert rotation shows as signer mismatch on every device (run /drift) |
| FM-08 | Staging root untrusted | `ERROR ... staging root untrusted` | Security or environment | A non-admin pre-created or modified `C:\ProgramData\IntuneRemediation`; investigate the device |
| FM-09 | Timeout | log shows `Timeout after <n>s` | Environment or script defect | Check `$TIMEOUT_*` budget and network; installer hung |
| FM-10 | Script produced no status line | Intune shows empty output with exit 0 | Script defect | A body path fell through without `Exit-WithCode` (skeleton rule) |
| FM-11 | Unparseable output | Output does not start with a contract token | Script defect / contract violation | Any `Write-Host` besides Exit-WithCode (HR-02) |
| FM-12 | Pending reboot never clears | Repeated `PENDING_REBOOT` over many cycles | Environment | Device not rebooting; user communication, not a script fix |
| FM-13 | Remediation succeeds but next detection says outdated | "Recurred" state | Script defect or app self-downgrade | Compare installed-version routine in both scripts (must be identical) |
| FM-14 | Registry view mismatch | App present but `NOT_INSTALLED` | Script defect | Script ran 32-bit; package must be 64-bit and use both views |
