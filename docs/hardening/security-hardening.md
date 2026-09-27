# Security hardening

Six places sensitive material could leak, checked against the running
application rather than against a document. ZynSign's security architecture is
a set of claims; a claim nobody checks quietly stops being true.

## The six sweeps

| Sweep | What it checks | What it does to do it |
|---|---|---|
| Temporary files | Every staging location is inside the system temporary directory — one the platform may reclaim at will | Reads locations only |
| Workspace cleanup scope | No temporary location is inside Documents, where a cleanup could reach what the user exported | Reads locations only |
| Backup behaviour | The library and the exports are left to the platform's backup — or the exclusion is reported, never assumed | Reads the flag |
| Exported files | The head of every file in the export and diagnostics directories, against the PEM markers that must never appear | Reads at most 64 KB of each of the first 200 files |
| Diagnostic log | Every entry's detail is a fixed slug: dot-separated lowercase words, and nothing else | Reads the log |
| Keychain access | Every stored identity reports non-exportable key storage, or its silence is reported | Lists identities and reads what the storage adapter says |

None of them writes. The export sweep is the most invasive thing the Lab does,
and it reads 64 KB from the head of a file.

## Findings and their severity

- **Key material in an exported file** — `Critical`, and an incident. Remove
  the file, then find the write path that produced it.
- **An identity whose key can be extracted** — `Critical`. It must not be
  reachable; re-import it so the key is stored non-extractably.
- **A temporary location inside Documents** — `High`. A cleanup that can reach
  Documents is a data-loss risk.
- **A log entry carrying free text** — `High`. The technical log's contract is
  a slug and nothing else; a call site that grew text is a privacy regression.

## What is enforced elsewhere

Some promises are architecture, and CI is what keeps them:

- **No private key and no certificate outside test fixtures** — the hygiene job
  refuses the commit.
- **No analytics, no telemetry, no crash-reporter SDK** — `AnalyticsPolicy`
  with `isEnabled == false`, no endpoint, and a local journal the user clears
  in one tap. Frozen by `AnalyticsPolicyTests` and `SecurityBoundaryTests`.
- **No force unwraps, no `try!`, no unwaived `as!`** —
  `Scripts/audit_crash_surface.py` refuses a build whose code and baseline
  disagree (see [the crash inventory](../development/continuous-integration.md)).
- **Pairing, JIT and usbmux stay unavailable** — an architecture fact, frozen
  by `PairingCapabilityTests`.

## What is not checked here

- The Keychain's own guarantee. ZynSign reports what the storage adapter says;
  it does not re-derive it.
- The whole of a large exported file — the sweep reads its head.
- Anything about a file the user exported themselves.

## If the log sweep fails

The technical log is opt-in, off by default, and carries a category, a
timestamp and a fixed slug per entry — no message, no value, no path.
`DiagnosticLogEntry`'s contract is what makes a report safe to share. A call
site that started writing text into `detail` is a defect in that call site, not
in the log.
