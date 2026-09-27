# RC 1 hardening pack

Everything ZynSign checked before calling this build a release candidate, and
everything it deliberately did not claim.

The pack exists because "we tested it" is not a claim a release can rest on.
What a release can rest on is a list of checks, the result of each, the
evidence behind it, and an honest statement of the checks that did not
execute. The Compatibility Lab produces that list on a device; the scripts
in this directory check what belongs to a host; this pack is where the two
meet.

## The three answers

Every check in the Lab answers the same three questions, because a validation
result nobody can act on is noise:

1. **What happened?** — the check's summary.
2. **What was verified?** — the precise claim, and its limits. Not "signing
   works", but "the package was read, structured, and a signing order was
   justified; nothing was signed".
3. **What next?** — for anything that is not a pass, the action that would
   settle it.

A check that cannot answer all three is not finished.

## Statuses

| Status | Meaning |
|---|---|
| Passed | The check ran and met its expectation. |
| Needs attention | It ran and met its expectation, with something worth a look. |
| Failed | It ran and did not meet its expectation. |
| Not run | It exists but did not execute in this environment. **An open question, not a pass.** |
| Not applicable | It does not apply to this environment (for example, split view on a phone). |

"Not run" outranks "Passed" whenever results roll up, so nine passes can never
hide one check that never executed. The release verdict is `Incomplete` until
every row is settled, and `Blocked` while a critical failure is open.

## Running it

```bash
# On a device or simulator: Settings → Compatibility Lab → Run the Lab
# Then export the report and build the browsable page:

python3 Scripts/generate_hardening_report.py --input path/to/compatibility-lab-*.json \
    --output build/hardening/index.html
```

The page shows the dashboard, every check with its evidence and measurements,
the host audits that ran beside it, and the notes about what the report does
not claim. With no device report supplied it still builds — and every device
row is reported as not run rather than filled in.

Host-side checks, all of which run in CI:

```bash
python3 Scripts/audit_crash_surface.py        # the crash-surface inventory
python3 Scripts/audit_accessibility.py        # colours, touch targets, text scaling
python3 Scripts/audit_regression_coverage.py  # the catalogue names real tests
python3 Scripts/generate_hardening_report.py  # the browsable page
```

## The pack

| Document | What it covers |
|---|---|
| [compatibility-lab.md](compatibility-lab.md) | The dashboard, the suites, and what a run touches |
| [signing-scenario-lab.md](signing-scenario-lab.md) | The eight package shapes, run for real |
| [ios-compatibility-matrix.md](ios-compatibility-matrix.md) | iOS 17, 18, 26 — and why 16 is not in the build |
| [device-compatibility-matrix.md](device-compatibility-matrix.md) | Phone and tablet classes, and the human pass |
| [performance-verification.md](performance-verification.md) | The benchmarks, and the one number ZynSign will not invent |
| [accessibility-audit.md](accessibility-audit.md) | Six items; three checked by the app, three by a person |
| [network-resilience.md](network-resilience.md) | Offline, slow, failing, malformed, truncated |
| [resource-resilience.md](resource-resilience.md) | Low storage, memory pressure, large imports, cleanup |
| [regression-suite.md](regression-suite.md) | What is frozen, and by which test |
| [security-hardening.md](security-hardening.md) | Temporary files, logs, Keychain, exports, backups, cleanup |
| [release-blockers.md](release-blockers.md) | Severity policy, the registry, and the checklist |

## What this pack does not claim

- **No device results are recorded here.** Every row in these documents
  describes what the Lab *executes* on the device it runs on. A row for
  another device or another iOS version is an open question until someone runs
  the Lab there and imports the report.
- **Nothing here is signed.** The Lab verifies preparation — structure,
  metadata, nested-code discovery, plan validation. Executing a signature
  needs an identity and a profile only the user has, and the Lab reports that
  absence rather than staging a fake one.
- **Installation remains a hand-off.** ZynSign builds the OTA manifest, the
  install link and the QR code, and says plainly that it has no delivery
  mechanism. No check in this pack claims otherwise.
- **Pairing, JIT and usbmux stay unavailable**, and off-device analytics stays
  off. Those are architecture facts, not test results.
