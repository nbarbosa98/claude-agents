"""Shared Graph plumbing for tools/graph/read/ and tools/graph/write/ (Phase 5, ADR-035).

Everything here is deterministic. External facts are cited inline; the full list is in
docs/decisions.md ADR-035. Sources:
  [GD]   microsoftgraph/microsoft-graph-docs-contrib @4ad99fd37a9e2e8538275a0a9cdff7907052f3ec
  [MSAL] msal 1.39.0 (PyPI wheel source), msal-extensions 1.3.1
  [ENTRA] MicrosoftDocs/entra-docs main, docs/identity-platform/*.md (retrieved 2026-10-03)

Layer 5 of the safety model (ADR-020): every tool re-checks, in process, that the tenant it
was given is on the allowlist and that the signed-in token was issued by that tenant (tid).
"""
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PLACEHOLDER_GUID = "00000000-0000-0000-0000-000000000000"

# [GD] api-reference/beta/api/intune-devices-devicehealthscript-*.md (Intune Remediations are
# beta-only) and api-reference/v1.0/api/group-*.md.
GRAPH_BETA = "https://graph.microsoft.com/beta"
GRAPH_V1 = "https://graph.microsoft.com/v1.0"
LOGIN_AUTHORITY = "https://login.microsoftonline.com/"

# Delegated scopes, least privileged per [GD] permission tables:
#   deviceHealthScripts create/update/assign: DeviceManagementScripts.ReadWrite.All
#   deviceHealthScripts list/get/assignments/deviceRunStates/runSummary: DeviceManagementScripts.Read.All
#   groups list/get: GroupMember.Read.All is listed (higher privileged than
#     Group-NestingSupport.ReadWrite.All, which is a write scope we do not want);
#   group members ($count): GroupMember.Read.All (least privileged).
SCOPES_READ = ["https://graph.microsoft.com/DeviceManagementScripts.Read.All",
               "https://graph.microsoft.com/GroupMember.Read.All"]
SCOPES_WRITE = ["https://graph.microsoft.com/DeviceManagementScripts.ReadWrite.All",
                "https://graph.microsoft.com/GroupMember.Read.All"]

MAX_RETRIES = 4
MAX_RETRY_AFTER = 60
HTTP_TIMEOUT = 60


class GraphError(Exception):
    """Any failure that must stop the tool. The message is safe to print."""


def config_path():
    return Path(os.environ.get("INTUNE_RMD_CONFIG", str(ROOT / "config" / "local.json")))


def load_config(path=None):
    p = Path(path) if path else config_path()
    try:
        cfg = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise GraphError("cannot read %s (%s); copy config/example.json and fill it in" % (p.name, type(e).__name__))
    return cfg


def allowlist(cfg):
    try:
        allow = cfg["tenant"]["allowlist"]
    except (KeyError, TypeError):
        return []
    if not isinstance(allow, list):
        return []
    return [a.lower() for a in allow if isinstance(a, str) and GUID_RE.match(a) and a != PLACEHOLDER_GUID]


def require_tenant(cfg, tenant):
    """Same rule as .claude/hooks/tenant-guard.py, repeated in process (layer 5)."""
    if not tenant or not GUID_RE.match(tenant):
        raise GraphError("--tenant must be a tenant GUID")
    allow = allowlist(cfg)
    if not allow:
        raise GraphError("tenant allowlist in config/local.json is empty or invalid; refusing")
    if tenant.lower() not in allow:
        raise GraphError("tenant is not on the allowlist; refusing")
    return tenant.lower()


def client_id(cfg):
    cid = ((cfg.get("auth") or {}).get("clientId") or "").strip()
    if not GUID_RE.match(cid) or cid == PLACEHOLDER_GUID:
        raise GraphError("auth.clientId in config/local.json is missing or a placeholder")
    return cid


def jwt_claims(token):
    """Decodes the payload of a JWT WITHOUT validating it. Used only on ID tokens, which are
    meant for the client; access tokens are opaque to clients ([ENTRA] access-tokens.md)."""
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part.encode("ascii")).decode("utf-8"))
    except (IndexError, ValueError, UnicodeError):
        raise GraphError("could not decode the ID token")


def check_tid(claims, tenant):
    """[ENTRA] id-token-claims-reference.md: `tid` is the GUID of the tenant the user signed in to."""
    tid = str((claims or {}).get("tid", "")).lower()
    if not tid:
        raise GraphError("ID token has no tid claim; refusing")
    if tid != tenant.lower():
        raise GraphError("signed-in token was issued by a different tenant than --tenant; refusing")
    return tid


class MsalAuth:
    """Delegated sign-in with the operator's own account (ADR-005).

    [MSAL] PublicClientApplication(client_id, authority=..., token_cache=...);
    acquire_token_silent(scopes, account); acquire_token_interactive(scopes, prompt=...),
    which needs the app registration's "Mobile and desktop applications" redirect URI
    http://localhost (msal/application.py docstring). The authority is pinned to the tenant.
    Token cache: msal_extensions.build_encrypted_persistence (Keychain on macOS); if that is not
    available the cache stays in memory (sign-in on every run). Never a plaintext file.
    """

    def __init__(self, cfg, tenant, scopes):
        import msal  # imported lazily so tests and --help work without it
        self.tenant = tenant
        self.scopes = scopes
        cache = self._cache(cfg)
        try:
            self.app = msal.PublicClientApplication(client_id(cfg), authority=LOGIN_AUTHORITY + tenant, token_cache=cache)
        except ValueError as e:  # msal raises ValueError when the authority cannot be resolved
            raise GraphError("cannot reach the sign-in authority for the tenant (%s)" % str(e).split(".")[0][:80])
        self._msal = msal

    def _cache(self, cfg):
        mode = ((cfg.get("auth") or {}).get("tokenCache") or "keychain").lower()
        if mode == "memory":
            return None
        try:
            from msal_extensions import PersistedTokenCache, build_encrypted_persistence
            loc = Path.home() / ".intune-rmd-scr-agent" / "msal-cache.bin"
            loc.parent.mkdir(mode=0o700, exist_ok=True)
            return PersistedTokenCache(build_encrypted_persistence(str(loc)))
        except Exception as e:  # noqa: BLE001 - any failure means no persistent cache
            print("note: encrypted token cache unavailable (%s); signing in without a cache" % type(e).__name__, file=sys.stderr)
            return None

    def _id_claims_from_cache(self, account):
        tc = self.app.token_cache
        ct = self._msal.TokenCache.CredentialType.ID_TOKEN
        for entry in tc.search(ct, query={"home_account_id": account["home_account_id"], "realm": self.tenant}):
            return jwt_claims(entry["secret"])
        return None

    def token(self):
        result, claims = None, None
        accounts = [a for a in self.app.get_accounts() if (a.get("realm") or "").lower() == self.tenant]
        if len(accounts) == 1:
            result = self.app.acquire_token_silent(self.scopes, account=accounts[0])
            if result and "access_token" in result:
                claims = result.get("id_token_claims") or self._id_claims_from_cache(accounts[0])
        if not result or "access_token" not in result:
            result = self.app.acquire_token_interactive(self.scopes, prompt="select_account")
            claims = result.get("id_token_claims")
        if "access_token" not in result:
            raise GraphError("sign-in failed: %s" % result.get("error", "unknown error"))
        check_tid(claims, self.tenant)
        return result["access_token"]


class UrllibTransport:
    def request(self, method, url, headers, body):
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), e.read()


class GraphClient:
    """Minimal Graph REST client: bearer auth, JSON, paging, bounded 429/503 retry."""

    def __init__(self, auth, transport=None, sleep=time.sleep):
        self.auth = auth
        self.transport = transport or UrllibTransport()
        self.sleep = sleep
        self._token = None
        self.calls = []

    def _headers(self, extra=None):
        if self._token is None:
            self._token = self.auth.token()
        h = {"Authorization": "Bearer " + self._token, "Accept": "application/json"}
        h.update(extra or {})
        return h

    def call(self, method, url, body=None, headers=None, expect=(200,)):
        data = None
        hdr = self._headers(headers)
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            hdr["Content-Type"] = "application/json"
        for attempt in range(MAX_RETRIES + 1):
            status, rh, raw = self.transport.request(method, url, hdr, data)
            self.calls.append((method, url, status))
            if status in (429, 503, 504) and attempt < MAX_RETRIES:
                ra = {k.lower(): v for k, v in (rh or {}).items()}.get("retry-after")
                try:
                    wait = min(int(ra), MAX_RETRY_AFTER)
                except (TypeError, ValueError):
                    wait = min(2 ** (attempt + 1), MAX_RETRY_AFTER)
                self.sleep(wait)
                continue
            break
        if status not in expect:
            raise GraphError("%s %s returned HTTP %s: %s" % (method, redact(url), status, error_text(raw)))
        if not raw:
            return None
        ctype = {k.lower(): v for k, v in (rh or {}).items()}.get("content-type", "")
        if "json" in ctype or raw[:1] in (b"{", b"["):
            return json.loads(raw.decode("utf-8"))
        return raw.decode("utf-8")

    def get(self, url, headers=None):
        return self.call("GET", url, headers=headers)

    def get_all(self, url, headers=None, max_pages=50):
        """Follows @odata.nextLink (standard Graph paging)."""
        out, n = [], 0
        while url:
            page = self.get(url, headers=headers)
            out.extend(page.get("value", []))
            url = page.get("@odata.nextLink")
            n += 1
            if n >= max_pages:
                raise GraphError("more than %d pages; refusing to continue" % max_pages)
        return out

    def count(self, url):
        """[GD] concepts/aad-advanced-queries.md: /$count needs ConsistencyLevel: eventual;
        group-list-members.md example 3: the response is text/plain."""
        v = self.get(url, headers={"ConsistencyLevel": "eventual"})
        try:
            return int(str(v).strip())
        except ValueError:
            raise GraphError("unexpected $count response")


def error_text(raw):
    try:
        e = json.loads(raw.decode("utf-8")).get("error", {})
        return "%s %s" % (e.get("code", ""), (e.get("message", "") or "")[:200])
    except (ValueError, AttributeError, UnicodeError):
        return "(no JSON error body)"


def redact(url):
    """Drops GUIDs from URLs in messages so error text does not carry identifiers."""
    return re.sub(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "{id}", url)


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def plan_hash(plan):
    body = {k: v for k, v in plan.items() if k not in ("planHash", "shortHash")}
    return sha256_bytes(canonical(body).encode("ascii"))


def out_root():
    return Path(os.environ.get("INTUNE_RMD_OUT", str(ROOT / "out"))).resolve()


def emit(obj, code=0):
    print(json.dumps(obj, indent=2))
    return code
