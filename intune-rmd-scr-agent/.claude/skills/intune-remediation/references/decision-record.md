# decision-record.json schema

Written by the classifier (app-update, vuln-remediation) or by the generator from the
orchestrator's brief (config-change, audit, general). Every `value` that came from
outside has a `source` (URL, or repo path + commit) and `retrievedAt`.

```json
{
  "schemaVersion": "1.0.0",
  "packageId": "upd-7zip",
  "type": "app-update",
  "pattern": "A",
  "subject": "7-Zip",
  "request": "original user request, verbatim",
  "confidence": "high | medium | low",
  "openQuestions": [],
  "evidence": [
    { "field": "wingetId", "value": "...", "source": "...", "retrievedAt": "ISO-8601" }
  ],
  "detection": {
    "displayNameLike": "...",
    "mainExePaths": ["..."],
    "userExeRelPaths": ["..."],
    "versionSource": "FileVersion | DisplayVersion"
  },
  "install": {
    "mechanism": "winget | msi | exe",
    "wingetId": "...",
    "includeUnknown": false,
    "downloadUrl": "...",
    "expectedSigner": { "CN": "...", "O": "..." },
    "sha256Published": true
  },
  "scope": { "machineInstallerAvailable": true, "decision": "machine-only (D2)" },
  "vuln": { "cveIds": [], "advisoryUrls": [], "fixKind": "version | mitigation", "affectedMin": "", "fixedVersion": "", "rebootRequired": false },
  "desiredState": [],
  "ownerApprovals": [ { "what": "...", "when": "ISO-8601", "quote": "..." } ],
  "vendorSchemaFingerprint": "sha256 of the sorted key paths of the vendor response (drift)"
}
```

Rules:

- `confidence: low` or a non-empty `openQuestions` stops the pipeline; the orchestrator
  asks the owner.
- Contradictory evidence (for example, two sources disagree on the signer) is an open
  question, never resolved by picking one.
