#!/usr/bin/env bash
# Builds PSScriptAnalyzer from source and installs it for the current user's PowerShell 7.
# Only needed where the PowerShell Gallery is blocked (the Claude Code cloud build
# environment). On a Mac, use: pwsh -c 'Install-Module PSScriptAnalyzer -Scope CurrentUser'
# (PSScriptAnalyzer README). Requires: git, pwsh, .NET 8 SDK (apt: dotnet-sdk-8.0).
# Provenance: github.com/PowerShell/PSScriptAnalyzer at the cloned commit; NuGet packages from
# nuget.org (the repo's own feed, pkgs.dev.azure.com, may be blocked). Pinned versions in the
# repo's Directory.Packages.props are unchanged.
set -euo pipefail
work="${1:-/tmp/pssa-src}"
rm -rf "$work"
git clone -q --depth 1 https://github.com/PowerShell/PSScriptAnalyzer "$work"
cd "$work"
echo "PSScriptAnalyzer source commit: $(git rev-parse HEAD)"
cat > NuGet.Config <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
XML
# Accept the installed .NET 8 SDK feature band.
printf '{ "sdk": { "version": "8.0.100", "rollForward": "latestFeature" } }\n' > global.json
# build.ps1 looks for dotnet in /usr/share/dotnet; Ubuntu's package installs to /usr/lib/dotnet.
if [ ! -e /usr/share/dotnet ] && [ -d /usr/lib/dotnet ]; then ln -s /usr/lib/dotnet /usr/share/dotnet; fi
pwsh -NoProfile -c './build.ps1 -Configuration Release -PSVersion 7' >/dev/null 2>&1 || true
src=$(ls -d "$work"/out/PSScriptAnalyzer/*/ | head -1)
[ -f "$src/PSScriptAnalyzer.psd1" ] || { echo "build failed" >&2; exit 1; }
dest="$HOME/.local/share/powershell/Modules/PSScriptAnalyzer"
rm -rf "$dest" && mkdir -p "$dest" && cp -r "$src" "$dest/"
pwsh -NoProfile -c 'Import-Module PSScriptAnalyzer; "PSScriptAnalyzer " + (Get-Module PSScriptAnalyzer).Version'
