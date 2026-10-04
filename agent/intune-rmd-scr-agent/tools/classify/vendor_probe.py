#!/usr/bin/env python3
"""Classifier tool: probe a vendor discovery endpoint and print JSON evidence.

Usage:
  python3 tools/classify/vendor_probe.py --url https://... --version-path a.b.0.version
        [--url-path a.b.0.url] [--sha256-path a.b.0.sha256] [--format json|text]
        [--version-regex REGEX] [--text-version-regex REGEX] [--timeout 30]
  python3 tools/classify/vendor_probe.py --file response.json ...   (offline, for tests)

No vendor URL or response layout is built in: every endpoint and field path comes from the
caller, with evidence, and is recorded in the decision record (rule: never guess an
external fact).

Paths: dot-separated keys; integers index arrays (for example releases.0.version).
Validation: the version must match --version-regex (default strict ^\\d+(\\.\\d+){1,3}$); the
download URL must be https; a SHA256 must be 64 hex characters.
Drift support: schemaFingerprint is the SHA256 of the sorted set of JSON key paths (array
indices collapsed to []), so a vendor changing its response layout changes the fingerprint.
"""
import datetime
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

DEFAULT_VERSION_RE = r"^\d+(\.\d+){1,3}$"


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def get_path(doc, path):
    cur = doc
    for part in path.split("."):
        if isinstance(cur, list) and re.fullmatch(r"\d+", part):
            i = int(part)
            if i >= len(cur):
                return None
            cur = cur[i]
        elif isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def key_paths(doc, prefix=""):
    out = set()
    if isinstance(doc, dict):
        for k, v in doc.items():
            p = "%s.%s" % (prefix, k) if prefix else str(k)
            out.add(p)
            out |= key_paths(v, p)
    elif isinstance(doc, list):
        for v in doc:
            out |= key_paths(v, prefix + "[]")
    return out


def fingerprint(doc):
    return hashlib.sha256("\n".join(sorted(key_paths(doc))).encode("utf-8")).hexdigest()


def fetch(url, timeout):
    if not url.startswith("https://"):
        raise ValueError("only https endpoints are allowed")
    req = urllib.request.Request(url, headers={"User-Agent": "intune-rmd-scr-agent/vendor-probe"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(), r.geturl()


def probe(argv):
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    url = arg(argv, "--url")
    src_file = arg(argv, "--file")
    fmt = arg(argv, "--format", "json")
    vre = re.compile(arg(argv, "--version-regex", DEFAULT_VERSION_RE))
    res = {"source": url or ("file:" + str(src_file)), "retrievedAt": now, "format": fmt, "valid": False, "errors": []}
    if src_file:
        body, final = Path(src_file).read_bytes(), None
    else:
        body, final = fetch(url, int(arg(argv, "--timeout", "30")))
        if final and final != url:
            res["redirectedTo"] = final
    res["bodySha256"] = hashlib.sha256(body).hexdigest()

    if fmt == "json":
        doc = json.loads(body.decode("utf-8"))
        res["schemaFingerprint"] = fingerprint(doc)
        vp = arg(argv, "--version-path")
        if not vp:
            raise ValueError("--version-path is required for json")
        version = get_path(doc, vp)
        dl = get_path(doc, arg(argv, "--url-path")) if arg(argv, "--url-path") else None
        sha = get_path(doc, arg(argv, "--sha256-path")) if arg(argv, "--sha256-path") else None
        res["paths"] = {"version": vp, "url": arg(argv, "--url-path"), "sha256": arg(argv, "--sha256-path")}
    elif fmt == "text":
        text = body.decode("utf-8", errors="replace")
        tre = arg(argv, "--text-version-regex")
        if not tre:
            raise ValueError("--text-version-regex is required for text")
        m = re.search(tre, text)
        version = m.group(1) if m and m.groups() else (m.group(0) if m else None)
        dl, sha = None, None
        res["schemaFingerprint"] = hashlib.sha256(("text:" + tre + ":" + ("match" if m else "nomatch")).encode()).hexdigest()
    else:
        raise ValueError("--format must be json or text")

    res["version"] = version
    res["downloadUrl"] = dl
    res["sha256"] = sha
    if not isinstance(version, str) or not vre.match(version):
        res["errors"].append("version %r does not match %s" % (version, vre.pattern))
    if dl is not None and (not isinstance(dl, str) or not dl.startswith("https://")):
        res["errors"].append("download URL is not https: %r" % (dl,))
    if sha is not None and (not isinstance(sha, str) or not re.fullmatch(r"[0-9A-Fa-f]{64}", sha)):
        res["errors"].append("sha256 is not 64 hex characters: %r" % (sha,))
    res["valid"] = not res["errors"]
    return res


def main(argv):
    if "--url" not in argv and "--file" not in argv:
        print(__doc__, file=sys.stderr)
        return 3
    try:
        res = probe(argv)
    except (ValueError, OSError, json.JSONDecodeError) as e:
        print(json.dumps({"valid": False, "errors": [str(e)]}, indent=2))
        return 1
    print(json.dumps(res, indent=2))
    return 0 if res["valid"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
