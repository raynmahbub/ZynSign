## [1.0.0-rc.1] — RC 1 · Production Hardening & Compatibility Lab

Market `1.0.0` build `5` (`CFBundleShortVersionString 1.0.0`, `CFBundleVersion 5`),
tag `v1.0.0-rc.1`. Release train promoted to `.rc1`: **every staged feature is
now visible** — Smart Sign, the signing queue, presets, the App Store and
repository health, background downloads, Entitlements Studio, Mission Control,
the installation delivery hand-off, the local activity journal, and batch
signing. `Signing Health Score` stays hidden until `1.0.0`.

**This candidate adds no user-facing feature.** Everything it adds is
validation: a Compatibility Lab that runs on the device, a crash-surface
inventory CI enforces, an error-recovery answer for every failure, and a
documentation set that says what was actually checked.

### Added

- **Compatibility Lab** *(Debug and internal builds only)* —
  `Settings → Compatibility Lab`. Ten suites run against the running app and
  the device: signing scenarios, iOS compatibility, device compatibility, store
  and downloads, resources, crash resilience, performance, security posture,
  accessibility, and regressions. The dashboard has the six rows a release
  decision reads; four further categories are reported beneath it. A run
  writes a deterministic JSON report and can build a browsable HTML page with
  `Scripts/generate_hardening_report.py`.
  See [docs/hardening/](../hardening/README.md).

- **Signing Scenario Lab** — eight package shapes (simple, frameworks,
  extensions, multiple bundles, unsigned, already signed, large, edge-case
  layout) built from nothing and read back through the production pipeline —
  twice each, because a result that cannot be reproduced is not a result. No
  real application, certificate, profile or key is involved, and nothing is
  signed: the lab verifies preparation.
  See [docs/hardening/signing-scenario-lab.md](../hardening/signing-scenario-lab.md).

- **Regression suite** — eleven frozen behaviours, each naming the tests that
  keep it frozen. Nine are asserted in the running app; two defer to the test
  target and say so rather than claiming a pass.
  `Scripts/audit_regression_coverage.py` refuses a catalogue that names a test
  type which does not exist.

- **Crash hardening** — ten crash-surface constructs across nine sites became
  five, all of them preview-fixture helpers, and CI refuses a build in which
  the code and the baseline disagree (`Scripts/audit_crash_surface.py`).
  Fixed along the way: an `as!` on a resolved `SecKey`, two force-unwrapped
  release-stage indices, a force-unwrapped executable path, a force-unwrapped
  modification date, three `URL(string:)…!` links, and an implicitly-unwrapped
  `URLSession` property that is now a `let`. There was never a `try!`.

- **Error recovery** — `ErrorRecoveryAdvisor` gives every failure the same
  three answers: what happened, what was verified, and what to do next. The
  mapping is over ZynSign's own typed vocabulary — identity, profile, CMS,
  crypto, nested code — with the category as the fallback, so a failure mode
  nobody has written advice for still arrives with an answer.

- **Host audits** — three scripts, all running in CI: the crash-surface
  inventory, an accessibility source audit (hard-coded colours, undersized
  controls, text scaling, with reviewed waivers), and the regression
  catalogue.

### Changed

- **Repository health is testable** — `RepositoryHealthProbe` fetches through
  an injectable `RepositoryHealthTransport`, so offline, slow, failing,
  malformed and truncated responses are reproduced rather than waited for.
- **A transport failure is reduced to a word** — `timeout`, `offline`,
  `connection lost`, `cancelled`, `host not found`, `tls`, `bad response` or
  `transport`. The category is shown in the interface and written into
  reports, so it must not carry what the network said about itself.
- **Settings sections can be validation-only** — a new
  `SettingsSectionDescriptor.isValidationOnly` keeps a section out of the
  lists a build that cannot run it would show, without unregistering it.

### Known limitations

Carried in `ReleaseBlockerRecord.registry` and shown in the Lab:

- In-app installation has no available mechanism. ZynSign builds the OTA
  manifest, the install link and the QR code and hands off; it never claims an
  install. *(Low, accepted — a platform fact.)*
- The device and iOS matrices need physical-device confirmation. The Lab
  executes on the device it runs on and records every other row as not run.
  *(Medium, open.)*
- Signing scenarios stop at preparation without signing material on the
  device. *(Medium, open.)*
- Performance figures measured on a simulator are not device figures, and the
  report says so. *(Low, accepted.)*

### What this candidate deliberately does not claim

- No device or iOS row is filled in from anything but a run on that device.
- No signature was produced by the Lab, and no check implies one.
- No frame rate is measured in-process; the scrolling row names the protocol
  that settles it.
- Pairing, JIT and usbmux stay unavailable, and off-device analytics stays
  off. Those are architecture facts, not test results.

### Testing

New unit tests: `CompatibilityLabScenarioTests`,
`CompatibilityLabReportTests`, `CompatibilityLabIntegrationTests`,
`ErrorRecoveryAdvisorTests`, `StoreResilienceTests` and
`DownloadsResilienceTests`. **Their results belong to CI** — the
`Build and test (Xcode)` job is the judge, and this note claims nothing about
them until it has run.

Host audits, run on the machine that produced this note:

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | 5 constructs, every one justified (all preview fixtures) |
| `Scripts/audit_accessibility.py` | 0 findings; 2 waived after review; 5 text-scaling items to review |
| `Scripts/audit_regression_coverage.py` | 11 behaviours, 9 executed in-app, 2 deferred; every named test type exists |

No device row in this note is filled in. Run the Compatibility Lab on a device
and import its report to settle them.
