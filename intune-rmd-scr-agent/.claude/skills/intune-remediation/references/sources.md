# Sources

Every external fact used by this skill, with where it was verified. Fetched 2026-09-27
unless stated. `learn.microsoft.com` is blocked from the build environment, so official
docs are read from their source repositories (ADR-010).

| Fact | Used in | Source |
|---|---|---|
| Remediations package rules, exit 1 triggers remediation, 2,048-char output, UTF-8 / no BOM, Bypass policy, schedules, licensing, RBAC category | platform.md, contract | MicrosoftDocs/memdocs `intune/device-management/tools/deploy-remediations.md` @4b5429d |
| Microsoft samples use `Write-Host` + `exit 0/1` | helpers.ps1 `Exit-WithCode` | MicrosoftDocs/memdocs `intune/device-management/tools/ref-remediation-scripts.md` @4b5429d, lines 51-58 |
| winget CLI not supported in SYSTEM context; `Microsoft.WinGet.Client` is | ADR-016, HR-15 | MicrosoftDocs/windows-dev-docs `hub/package-manager/winget/troubleshooting.md` (branch docs), "System Context" |
| `winget upgrade` options `--id --exact --source --scope --silent --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity` | helpers.ps1 `Invoke-Winget` | MicrosoftDocs/windows-dev-docs `hub/package-manager/winget/upgrade.md` |
| `winget show` options `--id --exact --source --versions --accept-source-agreements --disable-interactivity` | helpers.ps1 `Get-WingetCatalogVersion` | MicrosoftDocs/windows-dev-docs `hub/package-manager/winget/show.md` |
| winget return codes 0x8A15002B, 0x8A150014, 0x8A150109 (decimal values) | helpers.ps1 constants | microsoft/winget-cli `doc/windows/package-manager/winget/returnCodes.md` (master) |
| `Get-AuthenticodeSignature -LiteralPath`, status `Valid` | helpers.ps1 `Test-InstallerTrust` | MicrosoftDocs/PowerShell-Docs `reference/5.1/Microsoft.PowerShell.Security/Get-AuthenticodeSignature.md` |
| `Get-FileHash -LiteralPath -Algorithm SHA256` | helpers.ps1 | MicrosoftDocs/PowerShell-Docs `reference/5.1/Microsoft.PowerShell.Utility/Get-FileHash.md` |
| `Set-Acl` with `SetAccessRuleProtection` | helpers.ps1 `Set-TrustedAcl` | MicrosoftDocs/PowerShell-Docs `reference/5.1/Microsoft.PowerShell.Security/Set-Acl.md` |
| `Start-Process -NoNewWindow -PassThru -RedirectStandardOutput -ArgumentList` | helpers.ps1 | MicrosoftDocs/PowerShell-Docs `reference/5.1/Microsoft.PowerShell.Management/Start-Process.md` |
| HKLM `...\CurrentVersion\Uninstall` holds `DisplayVersion` | helpers.ps1 `Get-MachineInstalls` | MicrosoftDocs/win32 `desktop-src/Msi/uninstall-registry-key.md` (branch docs) |
| `RegistryView.Registry32` / `Registry64` | helpers.ps1 `Get-MachineInstalls` | dotnet/dotnet-api-docs `xml/Microsoft.Win32/RegistryView.xml` |
| winget-pkgs manifest path layout and installer field names (schema 1.12.0) | tools/classify/winget_manifest_lookup.py | microsoft/winget-pkgs `doc/manifest/schema/1.12.0/installer.md`; nested folders for multi-dot ids observed live (ADR-025) |
| PSScriptAnalyzer rule names, `PSUseCompatibleSyntax` / `PSUseCompatibleCommands` settings and the 5.1 profile name | tools/lint/PSScriptAnalyzerSettings.psd1 | MicrosoftDocs/PowerShell-Docs-Modules `reference/docs-conceptual/PSScriptAnalyzer/Rules/*.md` |

## UNVERIFIED (design assumptions to confirm in the lab)

| Item | Where | Plan |
|---|---|---|
| Platform execution timeout | HR-04 | Phase 3: long-running test script |
| IME PowerShell host version and invocation (`-File`?) | ADR-009, HR-03 | Phase 3/5: log `$PSVersionTable` and command line |
| `winget.exe` location pattern `Microsoft.DesktopAppInstaller_*_<arch>__8wekyb3d8bbwe` and that it runs as SYSTEM | `Get-WingetPath` | Phase 3 on the Gate 4 VM |
| `winget show --versions` prints one bare version per line in every UI language | `Get-WingetCatalogVersion` | Phase 3, plus a non-English image if available |
| `Start-Process -PassThru` needs `$p.Handle` touched for `ExitCode` on 5.1 | `Invoke-ProcessWithTimeout` | Phase 3 |
| `exit` inside `try` runs `finally` on 5.1 (observed on PowerShell 7) | skeleton | Phase 3 |
| Entra ID user SIDs start with `S-1-12-1-` | `Get-UserScopeInstalls` | Phase 3 with an Entra user profile |
| Browser "staged update" indicators per vendor | type-app-update.md | Per package, with evidence, lab-verified |
| "Collect diagnostics" includes IME Logs custom files | D3 | Phase 5 |
