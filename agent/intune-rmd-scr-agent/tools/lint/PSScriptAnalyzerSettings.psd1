# Gate 1 PSScriptAnalyzer settings (committed; changes need owner approval).
# Rule names and settings syntax verified against MicrosoftDocs/PowerShell-Docs-Modules
# reference/docs-conceptual/PSScriptAnalyzer/Rules/*.md (fetched 2026-09-28).
@{
    Severity     = @('Error', 'Warning')

    # PSAvoidUsingWriteHost: Write-Host is deliberate. It is the only status channel, used
    # once per run by Exit-WithCode and by the outer catch, matching Microsoft's Remediations
    # samples (HR-02; memdocs ref-remediation-scripts.md). Everything else is banned by Gate 1.
    ExcludeRules = @('PSAvoidUsingWriteHost')

    Rules        = @{
        # HR-11: scripts must run on Windows PowerShell 5.1.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        # HR-11: cmdlets and parameters must exist in Windows PowerShell 5.1 on Windows 10.
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
