#!/usr/bin/env python3
"""Gate 1: deterministic linter for an Intune Remediation package.

Usage:
  python3 tools/lint/lint.py <package-dir> [--out gate1.json] [--no-pssa]

Reads contract/stdout.json and the canonical helpers, parses each script with
tools/lint/Get-ScriptFacts.ps1 (PowerShell AST, never executes the script), merges
PSScriptAnalyzer findings from tools/lint/Invoke-PSSA.ps1 when the module is available,
and prints a JSON result:

  {"gate": "gate1", "package": ..., "status": "PASS|FAIL|PASS_PENDING_PSSA",
   "pssa": "ran|unavailable|skipped", "budget": {...}, "findings": [
     {"rule_id", "severity", "file", "line", "evidence"}]}

Exit code: 0 for PASS, 1 for FAIL, 2 for PASS_PENDING_PSSA (not deliverable), 3 usage.
Rule changes need explicit owner approval (CLAUDE.md).
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "classify"))
from validate_decision_record import validate as validate_decision_record  # noqa: E402

CONTRACT = ROOT / "contract" / "stdout.json"
REF = ROOT / ".claude" / "skills" / "intune-remediation" / "references"
HELPERS = REF / "helpers.ps1"
FACTS = ROOT / "tools" / "lint" / "Get-ScriptFacts.ps1"
PSSA = ROOT / "tools" / "lint" / "Invoke-PSSA.ps1"

BUDGET_CEILING = 540
# Invoke-ProcessWithTimeout waits up to 15 s for taskkill after a timeout.
PROCESS_KILL_OVERHEAD = 15
PROCESS_HELPERS = {"Invoke-ProcessWithTimeout", "Invoke-Winget", "Get-WingetCatalogVersion"}
TIMEOUT_PARAMS = {"TimeoutSeconds", "TimeoutSec"}
BANNED_ENV = {"LOCALAPPDATA", "APPDATA", "USERPROFILE", "HOMEPATH", "HOMEDRIVE", "USERNAME", "TEMP", "TMP"}
STDOUT_CMDS = {"Write-Host", "Write-Output", "echo", "Write-Information", "Out-Host", "Out-Default", "Write"}
README_SECTIONS = ["## Summary", "## Type and pattern", "## Evidence", "## Status tokens", "## Intune settings",
                   "## Time budget", "## Known failure modes", "## Rollback", "## UNVERIFIED items"]
CATCH_RETHROW = "if ($_.Exception.Message -like 'ExitCalled:*') { throw }"
AUDIT_BANNED_PREFIX = ("Set-", "New-", "Remove-", "Stop-", "Restart-", "Start-", "Clear-", "Rename-", "Move-",
                       "Copy-", "Install-", "Uninstall-", "Register-", "Unregister-", "Enable-", "Disable-",
                       "Add-", "Update-", "Invoke-FileDownload", "Invoke-ProcessWithTimeout", "Invoke-Winget",
                       "Set-DesiredStateEntry")
AUDIT_ALLOWED = {"Initialize-Log", "Write-RemediationLog", "Exit-WithCode", "New-Object"}
PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__|<AppDisplayName>")


class Linter:
    def __init__(self, pkg, use_pssa=True):
        self.pkg = Path(pkg).resolve()
        self.use_pssa = use_pssa
        self.findings = []
        self.contract = json.loads(CONTRACT.read_text(encoding="ascii"))
        self.pwsh = shutil.which("pwsh")
        self.budget = {}
        self.pssa_status = "skipped"

    # ---- helpers ----
    def add(self, rule, sev, file, line, evidence):
        self.findings.append({"rule_id": rule, "severity": sev, "file": file, "line": line, "evidence": str(evidence)[:300]})

    def facts(self, path):
        r = subprocess.run([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(FACTS), "-Path", str(path)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("Get-ScriptFacts failed for %s: %s" % (path, r.stderr.strip()[:500]))
        return json.loads(r.stdout)

    def allowed(self, type_, role):
        """token -> exit code for this type and role."""
        out = {}
        for t in self.contract["tokens"]:
            if type_ in t["types"]:
                for e in t["emits"]:
                    if e["script"] == role:
                        out[t["token"]] = e["exitCode"]
        return out

    # ---- entry ----
    def run(self):
        if not self.pwsh:
            self.add("L-ENV-PWSH", "error", "", 0, "pwsh (PowerShell 7) not found; Gate 1 cannot run")
            return self.result(None)
        dr = self.check_decision_record()
        type_ = (dr or {}).get("type")
        pattern = (dr or {}).get("pattern")
        if type_ not in self.contract["types"]:
            self.add("L-TYPE", "error", "decision-record.json", 0, "unknown or missing type: %r" % type_)
            return self.result(type_)
        canon = {f["name"]: f["text"].replace("\r\n", "\n") for f in self.facts(HELPERS)["functions"]}
        roles = self.contract["scriptsByType"][type_]
        per_role = {}
        for role in ("detect", "remediate"):
            f = self.pkg / ("%s.ps1" % role)
            if role not in roles:
                if f.exists():
                    self.add("L-AUDIT-NOREMEDIATE", "error", f.name, 0, "type %s must not have a %s script" % (type_, role))
                continue
            if not f.exists():
                self.add("L-MISSING-SCRIPT", "error", f.name, 0, "missing %s script" % role)
                continue
            per_role[role] = self.check_script(f, role, type_, pattern, canon)
        self.check_cross(per_role, pattern)
        self.check_decision_constants(per_role, dr)
        self.check_readme(type_)
        if self.use_pssa:
            self.run_pssa([self.pkg / ("%s.ps1" % r) for r in per_role])
        return self.result(type_)

    def result(self, type_):
        errors = [f for f in self.findings if f["severity"] == "error"]
        if errors:
            status = "FAIL"
        elif self.pssa_status != "ran":
            status = "PASS_PENDING_PSSA"
        else:
            status = "PASS"
        return {"gate": "gate1", "package": self.pkg.name, "type": type_, "status": status, "pssa": self.pssa_status,
                "budget": self.budget, "findings": self.findings}

    # ---- decision record ----
    def check_decision_record(self):
        p = self.pkg / "decision-record.json"
        if not p.exists():
            self.add("L-DECISION", "error", p.name, 0, "decision-record.json missing")
            return None
        try:
            dr = json.loads(p.read_text(encoding="utf-8"))
        except ValueError as e:
            self.add("L-DECISION", "error", p.name, 0, "invalid JSON: %s" % e)
            return None
        if dr.get("packageId") != self.pkg.name:
            self.add("L-DECISION", "error", p.name, 0, "packageId %r does not match folder %r" % (dr.get("packageId"), self.pkg.name))
        errors, stop = validate_decision_record(dr)
        for err in errors:
            self.add("L-DECISION", "error", p.name, 0, err)
        if stop:
            self.add("L-DECISION", "error", p.name, 0, "confidence is low or open questions remain: the owner must answer first")
        return dr

    # ---- one script ----
    def check_script(self, path, role, type_, pattern, canon):
        name = path.name
        raw = path.read_bytes()
        for i, line in enumerate(raw.split(b"\n"), 1):
            bad = [b for b in line if b > 0x7F]
            if bad:
                self.add("L-ASCII", "error", name, i, "non-ASCII byte 0x%02X (HR-01)" % bad[0])
        if raw.startswith(b"\xef\xbb\xbf"):
            self.add("L-ASCII", "error", name, 1, "UTF-8 BOM present (HR-01)")
        text = raw.decode("ascii", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            m = PLACEHOLDER.search(line)
            if m:
                self.add("L-PLACEHOLDER", "error", name, i, "unsubstituted placeholder %s" % m.group(0))

        fx = self.facts(path)
        for e in fx["parseErrors"]:
            self.add("L-PARSE", "error", name, e["line"], e["message"])
        for e in fx["ps7Syntax"]:
            self.add("L-PS7", "error", name, e["line"], "%s: %s (HR-11)" % (e["id"], e["text"]))
        if fx["parseErrors"]:
            return fx

        helpers_here = {f["name"] for f in fx["functions"] if f["name"] in canon}
        self.check_header(text, name, role, type_)
        self.check_order(fx, name)
        self.check_helpers(fx, name, canon)
        self.check_status(fx, name, role, type_)
        self.check_exits(fx, name, role)
        self.check_process_and_web(fx, name, set(canon))
        self.check_env(fx, name)
        self.check_logging(fx, name, role)
        self.check_staging(fx, name, role, text)
        self.check_budget(fx, name, role)
        self.check_winget(fx, name, pattern, text)
        self.check_safety(fx, name, type_, text)
        return fx

    def outside_helpers(self, items, canon_names=None):
        return [x for x in items if not x.get("function")]

    def check_header(self, text, name, role, type_):
        head = text[:800]
        for key, want in (("Package", self.pkg.name), ("Type", type_), ("Role", role)):
            m = re.search(r"^%s:\s*(\S+)" % key, head, re.M)
            if not m or m.group(1) != want:
                self.add("L-HEADER", "error", name, 1, "header %s must be %r (found %r)" % (key, want, m.group(1) if m else None))

    def check_order(self, fx, name):
        kinds = [t["kind"] for t in fx["topLevel"]]
        if not kinds or kinds[-1] != "try":
            self.add("L-ORDER", "error", name, fx["topLevel"][-1]["line"] if fx["topLevel"] else 0,
                     "the main try block must be the last top-level statement")
        seen_fn = False
        for t in fx["topLevel"]:
            if t["kind"] == "function":
                seen_fn = True
            elif t["kind"] == "assignment" and seen_fn and t["text"].strip() == "$stagingDir = $null":
                continue  # the remediation skeleton initialises $stagingDir right before the main try
            elif t["kind"] == "assignment" and seen_fn:
                self.add("L-ORDER", "error", name, t["line"], "constant after helpers: %s" % t["text"])
            elif t["kind"] == "other":
                self.add("L-ORDER", "error", name, t["line"], "unexpected top-level statement: %s" % t["text"])
        consts = {a["name"]: a for a in fx["assignments"]}
        pid = consts.get("PACKAGE_ID")
        if not pid or pid["value"] != self.pkg.name:
            self.add("L-ORDER", "error", name, pid["line"] if pid else 0, "$PACKAGE_ID must be the literal %r" % self.pkg.name)
        if "SUBJECT" not in consts:
            self.add("L-ORDER", "error", name, 0, "$SUBJECT constant missing")
        if fx["outerTry"] is None:
            self.add("L-ORDER", "error", name, 0, "no top-level try block")

    def check_helpers(self, fx, name, canon):
        for f in fx["functions"]:
            if f["name"] in canon:
                if f["text"].replace("\r\n", "\n") != canon[f["name"]]:
                    self.add("L-HELPER-VERBATIM", "error", name, f["startLine"],
                             "%s differs from references/helpers.ps1; copy it verbatim" % f["name"])
            else:
                self.add("L-HELPER-UNKNOWN", "warning", name, f["startLine"],
                         "function %s is not a canonical helper; reviewer must check it" % f["name"])
            if not f["topLevel"]:
                self.add("L-ORDER", "error", name, f["startLine"], "nested function %s" % f["name"])
        if "Exit-WithCode" not in {f["name"] for f in fx["functions"]}:
            self.add("L-EXIT", "error", name, 0, "Exit-WithCode is not defined (HR-03)")

    def check_status(self, fx, name, role, type_):
        allowed = self.allowed(type_, role)
        calls = [c for c in fx["commands"] if c["name"] == "Exit-WithCode" and not c["function"]]
        if not calls:
            self.add("L-STATUS-TOKEN", "error", name, 0, "no Exit-WithCode call in the main block")
        for c in calls:
            tok = c["params"].get("Token")
            code = c["params"].get("Code")
            if not tok or tok["kind"] != "literal":
                self.add("L-STATUS-NONLITERAL", "error", name, c["line"], "-Token must be a string literal: %s" % c["text"])
                continue
            if not code or code["kind"] != "literal":
                self.add("L-STATUS-NONLITERAL", "error", name, c["line"], "-Code must be a literal 0 or 1: %s" % c["text"])
                continue
            t = tok["value"]
            if t not in allowed:
                self.add("L-STATUS-TOKEN", "error", name, c["line"],
                         "token %s not allowed for type %s %s (contract): %s" % (t, type_, role, sorted(allowed)))
            elif int(code["value"]) != allowed[t]:
                self.add("L-STATUS-TOKEN", "error", name, c["line"],
                         "token %s must exit %d in %s, found %s" % (t, allowed[t], role, code["value"]))
            if "Message" not in c["params"]:
                self.add("L-STATUS-TOKEN", "error", name, c["line"], "-Message missing")
        for c in fx["commands"]:
            if c["name"] in STDOUT_CMDS and c["function"] != "Exit-WithCode" and not c["inOuterCatch"]:
                self.add("L-STDOUT", "error", name, c["line"], "stdout write outside Exit-WithCode: %s (HR-02)" % c["text"][:120])
        for m in fx["methodCalls"]:
            if m["target"] in ("[Console]", "[System.Console]") and m["member"] in ("WriteLine", "Write"):
                self.add("L-STDOUT", "error", name, m["line"], "[Console]::%s writes to stdout (HR-02)" % m["member"])
        catch_writes = [c for c in fx["commands"] if c["inOuterCatch"] and c["name"] in STDOUT_CMDS]
        for c in catch_writes:
            if "'ERROR | " not in c["text"]:
                self.add("L-STDOUT", "error", name, c["line"], "outer catch may only write the ERROR status line")

    def check_exits(self, fx, name, role):
        want = "0" if role == "detect" else "1"
        for x in fx["exits"]:
            if x["function"] == "Exit-WithCode":
                continue
            if x["inOuterCatch"]:
                if (x["value"] or "").strip() != want:
                    self.add("L-EXIT", "error", name, x["line"], "outer catch must exit %s in %s (HR-21)" % (want, role))
                continue
            self.add("L-EXIT", "error", name, x["line"], "raw exit outside Exit-WithCode and the outer catch (HR-03)")
        ot = fx["outerTry"]
        if ot:
            first = re.sub(r"\s+", " ", (ot["firstCatchStatement"] or "")).strip()
            if first != CATCH_RETHROW:
                self.add("L-CATCH-RETHROW", "error", name, ot["line"],
                         "first statement of the outer catch must be: %s" % CATCH_RETHROW)
            if ot["catchCount"] != 1:
                self.add("L-CATCH-RETHROW", "error", name, ot["line"], "outer try must have exactly one catch")

    def check_process_and_web(self, fx, name, canon_names):
        # Canonical helper bodies are verified verbatim (L-HELPER-VERBATIM) and reviewed at
        # the source, and may use splatting the AST facts cannot resolve, so they are skipped
        # here. A non-canonical function is still checked.
        for m in fx["methodCalls"]:
            if m["member"] == "WaitForExit" and m["argCount"] == 0:
                self.add("L-WAIT", "error", name, m["line"], "WaitForExit() without a timeout (HR-05)")
        for c in fx["commands"]:
            if c["function"] in canon_names:
                continue
            n = c["name"]
            if n == "Start-Process":
                if "Wait" in c["params"]:
                    self.add("L-WAIT", "error", name, c["line"], "Start-Process -Wait is unbounded (HR-05)")
                if "NoNewWindow" not in c["params"] and not ("NoNewWindow" in c["text"]):
                    self.add("L-NONEWWINDOW", "error", name, c["line"], "Start-Process without -NoNewWindow (HR-14)")
                if not c["function"]:
                    self.add("L-PROCESS", "error", name, c["line"], "use Invoke-ProcessWithTimeout, not Start-Process (HR-14)")
            if n == "Wait-Process" and "Timeout" not in c["params"]:
                self.add("L-WAIT", "error", name, c["line"], "Wait-Process without -Timeout (HR-05)")
            if n in ("Invoke-WebRequest", "Invoke-RestMethod", "iwr", "irm") and "TimeoutSec" not in c["params"]:
                self.add("L-WEB-TIMEOUT", "error", name, c["line"], "%s without -TimeoutSec (HR-05)" % n)
            if n in ("Invoke-WebRequest", "Invoke-RestMethod") and not c["function"]:
                self.add("L-WEB-TIMEOUT", "error", name, c["line"], "download only via Invoke-FileDownload (HR-07)")
            if n == "Start-Sleep" and c["inLoop"]:
                self.add("L-WAIT", "warning", name, c["line"], "Start-Sleep in a loop: reviewer must confirm a deadline (HR-05)")
            if n in ("Invoke-Expression", "iex"):
                self.add("L-IEX", "error", name, c["line"], "Invoke-Expression is not allowed")

    def check_env(self, fx, name):
        for v in fx["envVars"]:
            if v["name"].upper() in BANNED_ENV:
                self.add("L-ENV", "error", name, v["line"], "$env:%s is banned (HR-06/HR-07)" % v["name"])
        for m in fx["methodCalls"]:
            if m["member"] in ("GetFolderPath", "GetEnvironmentVariable", "ExpandEnvironmentVariables") and m["function"] != "Invoke-ProcessWithTimeout":
                self.add("L-ENV", "warning", name, m["line"], "%s: reviewer must confirm it is not a user-profile path (HR-06)" % m["member"])
        for s in fx["strings"]:
            val = s["value"] or ""
            if re.search(r"%(LOCALAPPDATA|APPDATA|USERPROFILE|TEMP|TMP)%", val, re.I):
                self.add("L-ENV", "error", name, s["line"], "user-profile environment reference in string (HR-06)")

    def check_logging(self, fx, name, role):
        ot = fx["outerTry"]
        first = (ot or {}).get("firstTryStatement") or ""
        if not re.match(r"Initialize-Log\s+-PackageId\s+\$PACKAGE_ID\s+-Role\s+'%s'\s*$" % role, first.strip()):
            self.add("L-LOG", "error", name, (ot or {}).get("line", 0),
                     "first statement in the main try must be: Initialize-Log -PackageId $PACKAGE_ID -Role '%s' (HR-10)" % role)
        for s in fx["strings"]:
            if s["function"]:
                continue
            val = s["value"] or ""
            if "IntuneManagementExtension" in val or re.search(r"\*_\*\.log|\*\.log", val):
                self.add("L-LOG", "error", name, s["line"], "log folder or log glob outside the canonical helpers (HR-10)")

    def check_staging(self, fx, name, role, text):
        main = [c for c in fx["commands"] if not c["function"]]
        downloads = [c for c in main if c["name"] == "Invoke-FileDownload"]
        runs_msi = re.search(r"msiexec", text, re.I) is not None
        if not downloads and not runs_msi:
            return
        if role != "remediate":
            self.add("L-STAGING", "error", name, downloads[0]["line"] if downloads else 0, "installer handling in a detection script")
            return
        stage = [c for c in main if c["name"] == "New-SecureStagingDir"]
        trust = [c for c in main if c["name"] == "Test-InstallerTrust"]
        if not stage:
            self.add("L-STAGING", "error", name, 0, "installer without New-SecureStagingDir (HR-07)")
        elif not re.search(r"\$stagingDir\s*=\s*New-SecureStagingDir", text):
            self.add("L-STAGING", "error", name, stage[0]["line"], "assign New-SecureStagingDir to $stagingDir so finally removes it (HR-07)")
        for d in downloads:
            out = d["params"].get("OutFile", {})
            if "$stagingDir" not in (out.get("text") or ""):
                self.add("L-STAGING", "error", name, d["line"], "-OutFile must be under $stagingDir (HR-07)")
        if not trust:
            self.add("L-TRUST", "error", name, 0, "installer without Test-InstallerTrust (HR-08)")
        else:
            first_dl = min([d["line"] for d in downloads] or [0])
            runs = [c for c in main if c["name"] == "Invoke-ProcessWithTimeout" and c["line"] > first_dl]
            for r in runs:
                if not any(t["line"] < r["line"] for t in trust):
                    self.add("L-TRUST", "error", name, r["line"], "installer run before Test-InstallerTrust (HR-08)")
            if ".Trusted" not in text:
                self.add("L-TRUST", "error", name, trust[0]["line"], "Test-InstallerTrust result is never checked (.Trusted) (HR-08)")
        fin = (fx["outerTry"] or {}).get("finallyText") or ""
        if "Remove-SecureStagingDir -Path $stagingDir" not in fin:
            self.add("L-STAGING", "error", name, 0, "finally must call Remove-SecureStagingDir -Path $stagingDir (HR-07)")

    def check_budget(self, fx, name, role):
        consts = {a["name"]: a for a in fx["assignments"] if a["name"] and a["name"].startswith("TIMEOUT_")}
        for a in consts.values():
            if a["kind"] != "literal" or not isinstance(a["value"], int):
                self.add("L-TIMEOUT-CONST", "error", name, a["line"], "%s must be an integer literal (HR-04)" % a["name"])
        total = 0
        for c in fx["commands"]:
            if c["function"]:
                continue
            for p in TIMEOUT_PARAMS:
                if p in c["params"]:
                    v = c["params"][p]
                    if v["kind"] != "variable" or not str(v["value"]).startswith("TIMEOUT_"):
                        self.add("L-TIMEOUT-CONST", "error", name, c["line"], "-%s must be a $TIMEOUT_* constant (HR-04)" % p)
                        continue
                    const = consts.get(v["value"])
                    if not const or not isinstance(const["value"], int):
                        self.add("L-TIMEOUT-CONST", "error", name, c["line"], "$%s is not declared as a constant" % v["value"])
                        continue
                    total += const["value"]
                    if c["inLoop"]:
                        self.add("L-TIMEOUT-LOOP", "warning", name, c["line"],
                                 "timeout inside a loop is counted once; reviewer must bound the iterations")
            if c["name"] in PROCESS_HELPERS:
                total += PROCESS_KILL_OVERHEAD
        self.budget[role] = total
        if total > BUDGET_CEILING:
            self.add("L-BUDGET", "error", name, 0, "static time budget %d s exceeds %d s (HR-04)" % (total, BUDGET_CEILING))

    def check_winget(self, fx, name, pattern, text):
        main = [c for c in fx["commands"] if not c["function"]]
        for c in main:
            if (c["name"] or "").lower() in ("winget", "winget.exe") or (c["invocation"] == "Ampersand" and "winget" in c["text"].lower()):
                self.add("L-WINGET-RAW", "error", name, c["line"], "call winget only via Invoke-Winget (HR-15)")
        for i, line in enumerate(text.splitlines(), 1):
            if re.search(r"source\s+(update|reset)", line, re.I):
                self.add("L-WINGET-SOURCE", "error", name, i, "winget source update/reset is not allowed (HR-15)")
        upgrades = [c for c in main if c["name"] == "Invoke-Winget" and (c["params"].get("Operation") or {}).get("value") == "upgrade"]
        if pattern == "Browser" and upgrades:
            self.add("L-BROWSER", "error", name, upgrades[0]["line"], "Browser pattern must not run winget upgrade (HR-15)")
        msi_lines = [i for i, l in enumerate(text.splitlines(), 1) if re.search(r"msiexec", l, re.I)]
        if msi_lines:
            for c in main:
                if c["name"] in ("Invoke-Winget", "Get-WingetCatalogVersion") and c["line"] > min(msi_lines):
                    self.add("L-WINGET-AFTER-MSI", "error", name, c["line"], "winget call after msiexec (HR-15)")
        for c in upgrades:
            iu = c["params"].get("IncludeUnknown")
            if not iu or "$INCLUDE_UNKNOWN" not in (iu.get("text") or ""):
                self.add("L-WINGET-PARITY", "error", name, c["line"], "upgrade must pass -IncludeUnknown:$INCLUDE_UNKNOWN (HR-15)")

    def check_safety(self, fx, name, type_, text):
        main = [c for c in fx["commands"] if not c["function"]]
        for c in fx["commands"]:
            n = c["name"] or ""
            if n in ("Restart-Computer", "Stop-Computer", "shutdown", "shutdown.exe"):
                self.add("L-REBOOT", "error", name, c["line"], "%s is not allowed (HR-20)" % n)
            if n in ("Stop-Process", "taskkill", "taskkill.exe", "kill") and not c["function"]:
                self.add("L-REBOOT", "error", name, c["line"], "stopping processes is not allowed (HR-20)")
        for i, line in enumerate(text.splitlines(), 1):
            if re.search(r"/forcerestart|/promptrestart|REBOOT=Force", line, re.I):
                self.add("L-REBOOT", "error", name, i, "forced restart flag (HR-20)")
            if re.search(r"HKCU:|HKEY_CURRENT_USER", line, re.I):
                self.add("L-HKCU", "error", name, i, "HKCU under SYSTEM is the SYSTEM hive; per-user writes are out of scope (HR-17)")
        if type_ == "audit":
            for c in main:
                n = c["name"] or ""
                if n in AUDIT_ALLOWED:
                    continue
                if n.startswith(AUDIT_BANNED_PREFIX) or n in ("reg", "reg.exe", "sc", "sc.exe", "msiexec", "msiexec.exe"):
                    self.add("L-AUDIT-READONLY", "error", name, c["line"], "state-changing command in an audit script: %s (HR-16)" % n)

    def check_cross(self, per_role, pattern):
        if pattern != "A" or "detect" not in per_role or "remediate" not in per_role:
            return
        vals = {}
        for role, fx in per_role.items():
            a = [x for x in fx.get("assignments", []) if x["name"] == "INCLUDE_UNKNOWN"]
            vals[role] = a[0]["value"] if a else None
        if vals["detect"] is None or vals["detect"] != vals["remediate"]:
            self.add("L-WINGET-PARITY", "error", "remediate.ps1", 0,
                     "$INCLUDE_UNKNOWN must be declared with the same literal in both scripts: %s" % vals)

    def check_decision_constants(self, per_role, dr):
        # Scalar app-update constants must equal the decision record, so evidence and scripts
        # cannot drift apart (added after the upd-7zip run, ADR-034).
        if not dr or dr.get("type") != "app-update":
            return
        det = dr.get("detection") or {}
        inst = dr.get("install") or {}
        want = {"DISPLAY_NAME_LIKE": det.get("displayNameLike"), "VERSION_SOURCE": det.get("versionSource")}
        if dr.get("pattern") == "A":
            want["WINGET_ID"] = inst.get("wingetId")
            want["INCLUDE_UNKNOWN"] = inst.get("includeUnknown")
        for role, fx in per_role.items():
            consts = {a["name"]: a for a in fx.get("assignments", [])}
            for name, value in want.items():
                if value is None:
                    continue
                a = consts.get(name)
                if not a or a["kind"] != "literal" or a["value"] != value:
                    self.add("L-DECISION-CONST", "error", "%s.ps1" % role, a["line"] if a else 0,
                             "$%s must be the literal %r from decision-record.json (found %r)" % (name, value, a["value"] if a else None))

    def check_readme(self, type_):
        p = self.pkg / "README.md"
        if not p.exists():
            self.add("L-README", "error", "README.md", 0, "README.md missing")
            return
        text = p.read_text(encoding="utf-8", errors="replace")
        pos = -1
        for s in README_SECTIONS:
            i = text.find("\n" + s + "\n")
            if i < 0:
                self.add("L-README", "error", "README.md", 0, "missing section %s" % s)
            elif i < pos:
                self.add("L-README", "error", "README.md", 0, "section out of order: %s" % s)
            else:
                pos = i
        if any(b > 0x7F for b in p.read_bytes()):
            self.add("L-ASCII", "error", "README.md", 0, "README.md contains non-ASCII bytes (HR-01)")
        self.check_readme_budget(text)

    def check_readme_budget(self, text):
        # The README states the worst-case time budget Gate 1 computed, in one fixed line, so
        # it can never drift from the scripts (owner decision after the upd-7zip run, ADR-034).
        m = re.search(r"\n## Time budget\n(.*?)(\n## |\Z)", text, re.S)
        if not m or not self.budget:
            return
        want = "Worst case (Gate 1): " + ", ".join("%s %d s" % (r, self.budget[r]) for r in ("detect", "remediate") if r in self.budget)
        if want not in m.group(1):
            self.add("L-README-BUDGET", "error", "README.md", 0,
                     "## Time budget must contain the line '%s' (computed by Gate 1)" % want)

    def run_pssa(self, files):
        r = subprocess.run([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(PSSA)] + [str(f) for f in files if f.exists()],
                           capture_output=True, text=True)
        if r.returncode == 3:
            self.pssa_status = "unavailable"
            return
        try:
            data = json.loads(r.stdout or "[]")
        except ValueError:
            self.add("L-PSSA", "error", "", 0, "PSScriptAnalyzer wrapper output unparseable: %s" % (r.stderr or r.stdout)[:300])
            self.pssa_status = "unavailable"
            return
        self.pssa_status = "ran"
        for d in data:
            sev = "error" if d.get("Severity") in ("Error", "ParseError") else "warning"
            self.add("PSSA-" + d.get("RuleName", "?"), sev, Path(d.get("ScriptPath", "")).name, d.get("Line", 0), d.get("Message", ""))


def main(argv):
    rest = list(argv[1:])
    out = None
    if "--out" in rest:
        i = rest.index("--out")
        if i + 1 >= len(rest):
            print(__doc__, file=sys.stderr)
            return 3
        out = rest[i + 1]
        del rest[i:i + 2]
    flags = [a for a in rest if a.startswith("--")]
    args = [a for a in rest if not a.startswith("--")]
    if len(args) != 1 or any(f not in ("--no-pssa",) for f in flags):
        print(__doc__, file=sys.stderr)
        return 3
    res = Linter(args[0], use_pssa="--no-pssa" not in flags).run()
    text = json.dumps(res, indent=2)
    if out:
        Path(out).write_text(text + "\n", encoding="ascii")
    print(text)
    return {"PASS": 0, "FAIL": 1, "PASS_PENDING_PSSA": 2}[res["status"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
