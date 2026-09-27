# Compatibility Lab

The Compatibility Lab is the single place a release candidate is judged. It is
compiled into Debug and internal builds only — it is validation apparatus, not
a feature, and a user has no reason to find it.

Settings → Compatibility Lab, in a Debug or internal build.

## The dashboard

Six rows, in the order a release decision reads them:

| Row | What the row proves |
|---|---|
| iOS Compatibility | ZynSign launches, imports, signs, exports and hands off on every supported iOS version |
| Device Compatibility | Layout, performance, memory, multitasking and orientation hold on every supported device class |
| Signing Pipeline | Every package shape ZynSign accepts is discovered, planned and validated reproducibly |
| Store Browser | Sources and downloads degrade gracefully on offline, slow, broken and partial responses |
| Performance | Launch, search, import, signing preparation, scrolling and memory stay inside the benchmarks |
| Crash Status | Cancellation, concurrency, hostile input and interrupted work end in typed recoveries |

Four further categories are reported beneath the dashboard and feed the same
verdict: **Security Posture**, **Accessibility**, **Resource Resilience**, and
**Regression Coverage**. They are not on the dashboard because the dashboard
keeps the shape a release decision reads — but an accessibility or security
regression blocks a candidate exactly as a broken pipeline does.

## Suites

Ten suites, run in this order:

| Suite | What it executes |
|---|---|
| Signing scenarios | Builds eight synthetic packages and reads them back through the production pipeline, twice each |
| iOS compatibility | Per release: launch, import, signing, store, export, installation |
| Device compatibility | Per class: layout, performance, memory, multitasking, orientation |
| Store and downloads | Offline, slow, failing, malformed, truncated; download workspace |
| Resources | Refusal before a copy, concurrent headroom, a memory spike, a large import, workspace accounting |
| Crash resilience | Cancellation, concurrency, hostile input, an interrupted run |
| Performance | First data read, search, import speed, signing preparation, scrolling, memory |
| Security posture | Temporary files, cleanup scope, backups, exported files, the log, the Keychain |
| Accessibility | Dynamic Type, Reduce Motion, contrast preference; VoiceOver and the rest are named, not measured |
| Regressions | The invariants that can be asserted in the running app, plus the tests that freeze the rest |

## What a run touches

Everything the Lab writes goes to one scratch directory under ZynSign's
temporary workspace:

```
tmp/ZynSignWork/CompatibilityLab/
```

It is swept before each run, so an interrupted run twice over does not inherit
the first one's files, and after each run, so nothing is left. The Lab:

- **builds** synthetic packages from nothing — no real application, no
  certificate, no profile, no key, no byte downloaded;
- **reads** them back through the production archive boundary
  (`ZipArchiveReader`, `IPAStructureValidator`, `ApplicationMetadataReader`,
  `NestedCodeDiscovery`, `NestedSigningPlanValidator`);
- **probes** repositories through injected transports, never over a network;
- **measures** with the process's own clock and the kernel's own memory
  report;
- **reads** the identity store, the export catalog and the storage footprint;
- **deletes** what it created.

The Lab never imports into the library, never signs, never exports an
artifact, and never runs a cleanup. A validation tool that can delete what the
user made is a liability, not a test.

## Overlays

Some checks cannot execute inside the app: a unit-test target's result belongs
to the test runner, and a device class this device is not belongs to another
device. Rather than invent a pass, the Lab reports `Not run` and can import the
answer from an overlay — a small JSON file dropped into `Documents/Diagnostics`
as `lab-overlay.json`:

```json
{
  "source": "Scripts/audit_accessibility.py on the host",
  "statuses": {
    "accessibility.contrast": "passed",
    "accessibility.touchTargets": "passed"
  }
}
```

Three rules govern overlays, and the code enforces all three:

1. An overlay can only fill a check that **did not run**. It can never overturn
   a measurement the Lab took itself.
2. Every imported row says where it came from, in its evidence.
3. The report names the overlay's source.

`Scripts/audit_accessibility.py --overlay-out <path>` writes one. So does a CI
job that runs the test target and records the result.

## The report

`Export report` writes JSON to `Documents/Diagnostics`; `Copy report as text`
puts a plain-text rendering on the pasteboard. The JSON is deterministic —
sorted keys, ISO-8601 timestamps — so two runs of the same build can be
diffed, and a report attached to RC 1 can be compared with one from RC 2 field
by field.

The report carries counts, classifications, durations and the fixed text of
its own checks. No absolute path, no credential, no key material, and nothing
of the user's.

## Reproducing a run on another device

1. Build a Debug or internal build on the device.
2. Settings → Compatibility Lab → Run the Lab.
3. Export the report, and repeat on each device class and iOS version in the
   matrices.
4. `python3 Scripts/generate_hardening_report.py --input <report>… ` to fold
   them into one page.

A run takes a few seconds and holds about twelve megabytes at its peak. It is
not a stress test, and it is never run in the background.
