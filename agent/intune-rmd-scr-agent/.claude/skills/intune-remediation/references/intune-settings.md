# Intune settings table

Every package README contains this table under `## Intune settings`, filled in. The
values are what `/deploy` will propose; the user confirms them during setup.

| Setting | Value | Why |
|---|---|---|
| Detection script | `detect.ps1` | |
| Remediation script | `remediate.ps1` (none for audit) | |
| Run this script using the logged-on credentials | No (runs as SYSTEM) | Machine-scope changes (ADR-009) |
| Enforce script signature check | No (v1, D5) | ADR-012 |
| Run script in 64-bit PowerShell | Yes | Native registry and Program Files views (ADR-009) |
| Schedule | proposed per type: app-update Daily, vuln Hourly (every 8 h), config-change Daily, audit Daily, general Daily | Confirmed during /deploy setup |
| Pilot group | named during /deploy | ADR-007 |
| Broad group | named during /deploy | ADR-007 |

Graph property names for these settings are verified in Phase 5 and recorded in
`docs/decisions.md`. The docs source lists `runAsAccount`, `enforceSignatureCheck`,
`runAs32Bit` and `detectionScriptContent` on the beta `deviceHealthScript` resource.
