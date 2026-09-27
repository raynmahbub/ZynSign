# Debugging

How failures are represented in ZynSign, and how to read them. The design
rule underneath everything here: failures are typed and categorized, never
reduced to free-form strings — and user-facing text never carries diagnostic
detail.

## The error model

`ZynSignError` (`ZynSign/Domain/ZynSignError.swift`) carries:

| Field | Audience | Rule |
|---|---|---|
| `userMessage` | the user | Shown directly; no technical detail, no wrapped-cause leakage |
| `diagnosticDetail` | logs and reports | Written by callers under the redaction rules — no key material, credentials, profile bodies, or user data |
| `category` | everything | One of the stable `DiagnosticCategory` values below |
| `underlyingError` | diagnosis only | Appears in the debug rendering, never in user-facing text |

`DiagnosticCategory` values: `invalidInput`, `unsupportedInput`,
`ambiguousInput`, `capabilityUnavailable`, `cancelled`, `storageFailure`,
`internalFailure`. Per-boundary reasons (identity, profile, CMS, crypto,
nested code) are typed enums on the error, not strings to grep.

## Reading a failure

1. **What the user saw** — `userMessage` and, in the interface,
   `ZErrorView`'s *what to do next* section.
2. **Which category** — the category decides the shape of the answer: an
   `invalidInput` names what was malformed; a `capabilityUnavailable` is a
   platform fact (recorded, not a bug); a `storageFailure` points at space or
   permissions.
3. **Where it stopped** — signing failures report the exact
   `SigningEngineStage`; nothing after that stage ran, and no container was
   delivered.

## Tools

- **Compatibility Lab** (`Settings → Compatibility Lab`, Debug builds) — ten
  suites against the running app and device, reduced to a verdict; results a
  human must produce are reported as *not run* and named.
- **Release Readiness Center** — weighted evidence report over the selected
  app/identity/profile/IPA configuration
  ([release-readiness.md](release-readiness.md)).
- **Hardening report** — `python3 Scripts/generate_hardening_report.py
  --output build/hardening/index.html`, then open the page.
- **Crash-surface inventory** — `python3 Scripts/audit_crash_surface.py`
  compares the code's actual force-try/force-unwrap surface against its
  recorded baseline; CI keeps both honest.
- **Release-stage preview** — launch argument `-ZynSignReleaseStage <stage>`
  pins which train features a Debug build shows.

## On-device storage, for diagnosis

| Path | Holds |
|---|---|
| `Application Support/ZynSignLibrary` | the library catalog and artifacts (versioned, SHA-256 dedupe) |
| `tmp/` | staging and working copies; swept by Mission Control after 24 h |
| `Documents/Signed` | signed output containers |
| `Downloads` cache | 500 MiB / 7 days, swept by Mission Control |

Nothing leaves the sandbox. When filing an issue, redact all of it.
