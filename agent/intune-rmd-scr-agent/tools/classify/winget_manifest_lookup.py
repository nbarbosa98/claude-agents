#!/usr/bin/env python3
"""Classifier tool: look up a package in microsoft/winget-pkgs and print JSON evidence.

Usage:
  python3 tools/classify/winget_manifest_lookup.py <PackageIdentifier> [--cache DIR] [--no-fetch]

Source access (ADR-025): a shallow, tree-less partial clone of
https://github.com/microsoft/winget-pkgs kept in out/cache/winget-pkgs. Trees and blobs are
fetched on demand by git, so only the package's own folders are downloaded. No GitHub API
token or rate limit is involved.

Verified facts this tool relies on (sources in docs/decisions.md ADR-025):
- Manifest path: manifests/<lowercase first character>/<identifier with '.' as '/'>/<version>/
  (example in doc/manifest/schema/1.12.0/installer.md:
  manifests/m/Microsoft/WindowsTerminal/1.9.1942/Microsoft.WindowsTerminal.installer.yaml;
  multi-dot identifiers observed as nested folders, e.g. manifests/m/Microsoft/VisualStudio/2022/Community).
- Installer fields: Installers[].Architecture, InstallerType, NestedInstallerType, Scope,
  InstallerSha256, InstallerUrl; InstallerType, NestedInstallerType and Scope may also be set at
  the manifest root and then apply to every installer (schema 1.12.0 installer.md).

Output fields: found, packageIdentifier, latestVersion, versions (count), manifestPath,
manifestUrl, commit, retrievedAt, installers[], scopes, machineScope, sha256Present,
installerTypes, publisher, packageName, warnings.
"""
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml  # PyYAML (tools/requirements.txt)

ROOT = Path(__file__).resolve().parents[2]
REPO_URL = "https://github.com/microsoft/winget-pkgs"
DEFAULT_CACHE = ROOT / "out" / "cache" / "winget-pkgs"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*\.[A-Za-z0-9._+-]+$")
ROOT_INHERITED = ("InstallerType", "NestedInstallerType", "Scope", "InstallerUrl", "InstallerSha256")


def git(cache, *args, timeout=300):
    r = subprocess.run(["git", "-C", str(cache)] + list(args), capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), r.stderr.strip()[:300]))
    return r.stdout


def ensure_cache(cache, fetch=True):
    if not (cache / ".git").exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=tree:0", "--no-checkout", REPO_URL, str(cache)],
                           capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            raise RuntimeError("clone failed: %s" % r.stderr.strip()[:300])
    elif fetch:
        git(cache, "fetch", "-q", "--depth", "1", "--filter=tree:0", "origin", "HEAD")
        git(cache, "update-ref", "HEAD", "FETCH_HEAD")


def package_dir(identifier):
    return "manifests/%s/%s" % (identifier[0].lower(), identifier.replace(".", "/"))


def version_key(v):
    """Approximate winget version ordering: numeric parts compared numerically, then text."""
    parts = re.split(r"[.\-+_]", v)
    key = []
    for p in parts:
        if p.isdigit():
            key.append((0, int(p), ""))
        else:
            m = re.match(r"^(\d+)(.*)$", p)
            key.append((0, int(m.group(1)), m.group(2)) if m else (1, 0, p))
    return key


def list_versions(cache, identifier):
    base = package_dir(identifier)
    try:
        files = git(cache, "ls-tree", "-r", "--name-only", "HEAD", base + "/").splitlines()
    except RuntimeError:
        return base, []
    versions = []
    pat = re.compile(r"^%s/([^/]+)/%s\.installer\.yaml$" % (re.escape(base), re.escape(identifier)))
    for f in files:
        m = pat.match(f)
        if m:
            versions.append(m.group(1))
    return base, sorted(set(versions), key=version_key)


def merge_installers(doc):
    out = []
    for inst in doc.get("Installers") or []:
        merged = {k: doc.get(k) for k in ROOT_INHERITED if doc.get(k) is not None}
        merged.update({k: v for k, v in inst.items() if v is not None})
        out.append({
            "architecture": merged.get("Architecture"),
            "installerType": merged.get("InstallerType"),
            "nestedInstallerType": merged.get("NestedInstallerType"),
            "scope": merged.get("Scope"),
            "installerSha256Present": bool(merged.get("InstallerSha256")),
            "installerUrl": merged.get("InstallerUrl"),
        })
    return out


def summarize(installers):
    scopes = sorted({i["scope"] for i in installers if i["scope"]})
    unscoped = any(not i["scope"] for i in installers)
    if "machine" in scopes:
        machine = "yes"
    elif unscoped:
        machine = "unknown"  # no Scope declared: the installer may support both; lab must confirm
    else:
        machine = "no"
    return {
        "scopes": scopes + (["<undeclared>"] if unscoped else []),
        "machineScope": machine,
        "sha256Present": all(i["installerSha256Present"] for i in installers) if installers else False,
        "installerTypes": sorted({"%s%s" % (i["installerType"], "/" + i["nestedInstallerType"] if i["nestedInstallerType"] else "")
                                  for i in installers if i["installerType"]}),
    }


def lookup(identifier, cache=DEFAULT_CACHE, fetch=True):
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    res = {"packageIdentifier": identifier, "found": False, "retrievedAt": now, "source": REPO_URL, "warnings": []}
    if not ID_RE.match(identifier):
        res["warnings"].append("identifier does not look like Publisher.Package")
        return res
    ensure_cache(cache, fetch)
    commit = git(cache, "rev-parse", "HEAD").strip()
    res["commit"] = commit
    base, versions = list_versions(cache, identifier)
    res["versions"] = len(versions)
    if not versions:
        return res
    latest = versions[-1]
    if not re.match(r"^\d+(\.\d+)*$", latest):
        res["warnings"].append("latest version %r is not purely numeric; ordering is approximate" % latest)
    path = "%s/%s/%s.installer.yaml" % (base, latest, identifier)
    doc = yaml.safe_load(git(cache, "show", "HEAD:" + path))
    installers = merge_installers(doc)
    res.update({
        "found": True,
        "latestVersion": latest,
        "manifestPath": path,
        "manifestUrl": "%s/blob/%s/%s" % (REPO_URL, commit, path),
        "installers": installers,
    })
    res.update(summarize(installers))
    try:
        ver_doc = yaml.safe_load(git(cache, "show", "HEAD:%s/%s/%s.yaml" % (base, latest, identifier)))
        loc = ver_doc.get("DefaultLocale")
        loc_doc = yaml.safe_load(git(cache, "show", "HEAD:%s/%s/%s.locale.%s.yaml" % (base, latest, identifier, loc)))
        res["publisher"] = loc_doc.get("Publisher")
        res["packageName"] = loc_doc.get("PackageName")
        res["warnings"].append("Publisher is the manifest's display value, not the Authenticode signer; verify the signer separately")
    except (RuntimeError, AttributeError, yaml.YAMLError):
        res["warnings"].append("default-locale manifest not readable")
    return res


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) < 1:
        print(__doc__, file=sys.stderr)
        return 3
    cache = DEFAULT_CACHE
    if "--cache" in argv:
        cache = Path(argv[argv.index("--cache") + 1])
        args = [a for a in args if a != str(cache)]
    try:
        res = lookup(args[0], cache, fetch="--no-fetch" not in argv)
    except (RuntimeError, subprocess.TimeoutExpired, yaml.YAMLError) as e:
        print(json.dumps({"packageIdentifier": args[0], "found": False, "error": str(e)}, indent=2))
        return 1
    print(json.dumps(res, indent=2))
    return 0 if res["found"] else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
