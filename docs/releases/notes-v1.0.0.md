## [1.0.0] — stable · the whole app, switched on

Market `1.0.0` build `10` (`CFBundleShortVersionString 1.0.0`,
`CFBundleVersion 9`), tag `v1.0.0`. Release train `.stable`: this release
switches on every staged feature the train has carried to here — Entitlements
Studio and the Developer Identity Center (`v0.1.0-alpha.3`), Mission Control,
the installation delivery hand-off, and the local activity journal
(`v0.9.0-beta.1`), the Installation Workspace and the Performance Engine
dashboard (`v0.9.0-beta.2`), the Smart Workspace (`v1.0.0-rc.2`), and the
Signing Health Score (`v1.0.0`) — and one stays hidden: the **Nova Assistant**,
which `v3.0.0-nova.1` switches on.

`1.0.0` is not a rewrite. Every surface below has been compiled since the alpha
that introduced it; this stop is the one that stops hiding them. Between
`v0.1.0-alpha.2` and here the train also carried four fixes-only rehearsals —
`v0.9.0-beta.3`, `v0.9.0-beta.4`, `v1.0.0-rc.1`, `v1.0.0-rc.3` — which is why
they introduce nothing of their own.

### Added

- **The Export Center** *(visible from `.stable`)* — every signed artifact
  ZynSign holds, newest first, with its verification, its availability, its
  size, and whether it has been handed to the system. Filter by verification,
  availability, and date; verify an artifact again, share it, reveal the
  application it was signed from in the Library, copy its reference, or delete
  it. The detail screen shows the signing operation that produced the artifact
  when the journal still holds one. The list is a projection of the catalog:
  an artifact whose file is gone stays listed and marked unavailable, a
  verification that could not run changes no row, and a deletion leaves the
  imported application and the signing history untouched. Reachable from Home,
  the Library toolbar, a signing result, Settings → General, and the signing
  history.
- **The signing history** *(visible from `.stable`)* — the journal's own
  screen: every run of the signing pipeline, including the ones that produced
  no artifact. A failure is a first-class row that opens the operation detail —
  the stage it stopped at, its category, the fixed-language explanation, and the
  technical detail behind a disclosure. Filter by outcome, verification, and
  date; clear the journal without touching an artifact, an application, or an
  identity.
- **Entitlements Studio** *(visible from `.stable`; introduced at
  `.alpha3`)* — read-only entitlements and profile compatibility for an
  application, from its detail screen, its signing run, and Settings →
  Diagnostics.
- **The Developer Identity Center** *(visible from `.stable`; introduced at
  `.alpha3`)* — teams, identity health, certificate and profile inspectors,
  conflicts, an expiration forecast, and the identity timeline, with the
  recommended identity surfaced on the signing screen.
- **Mission Control** *(visible from `.stable`; introduced at `.beta1`)* —
  Home → Refresh Everything refreshes sources, re-reads the library, and prunes
  caches in one pass, then reports what completed and what was unavailable.
  Re-signing is never auto-triggered.
- **Installation delivery hand-off** *(visible from `.stable`; introduced at
  `.beta1`)* — Sign → Deliver… produces the OTA `manifest.plist`, a
  percent-encoded install link, an on-device QR, and the step guides for OTA,
  MDM, and host tooling. HTTPS only; ZynSign uploads nothing, hosts nothing,
  probes nothing, and learns no install outcome.
- **The local activity journal** *(visible from `.stable`; introduced at
  `.beta1`)* — a bounded JSONL journal in the app container recording category,
  fixed slug, outcome, and time, with live counts, recent activity, one-tap
  clear, and export. Off-device measurement stays `false`, the endpoint `nil`,
  and the sent-event count zero.
- **The Installation Workspace** *(visible from `.stable`; introduced at
  `.beta2`)* — readiness checklists, the installed applications library,
  delivery attempts and confirmations, installation history, the artifact
  relationship view, and storage awareness. In-app installation of arbitrary
  IPAs is unavailable on every path; each row names the requirement it is
  missing instead of failing anonymously.
- **The Performance Engine dashboard** *(visible from `.stable`; introduced at
  `.beta2`)* — Settings → Advanced → Performance: library and index counts,
  cache statistics by category, the search index's status, benchmarks with
  regression detection, and manual optimization.
- **The Smart Workspace** *(visible from `.stable`; introduced at
  `.rc2`)* — Home is the command center: a daypart greeting, widgets ordered by
  what the person actually opens, Continue Last Session, and the Nova
  Assistant's suggestions when that stop arrives. Each card opens the tab that
  owns the work; Home's import doors are unchanged.
- **The Signing Health Score** *(visible from `.stable`)* — a pre-sign
  assessment that predicts whether an identity, profile, and bundle combination
  will succeed before the pipeline runs, shown on the signing screen.

### Changed

- **A presentation port the shell never installs is now a CI failure.**
  `Scripts/audit_presentation_ports.py` reads every `*Presentation` value in
  `Presentation/` and requires `RootView` to install each one. A port left
  uninstalled hands every caller the default no-op: the surface exists, the
  tests pass, and nothing can reach it — which is how the Export Center stayed
  invisible while its use case, model, and detail screen were complete. A port
  that is deliberately not installed must be recorded in
  `Scripts/ci/presentation-port-deferrals.txt`, and a repaid deferral fails.
- **The Library can be opened at one application.** `ApplicationLibraryView`
  takes an `initialRecord`; the Export Center's *Reveal in Library* switches
  tabs, pushes that application, then clears the request so a later visit is an
  ordinary visit.
- **`HomeView` composes the workspace only when the service and the gate
  agree** — a build before the `.rc2` stop holds no workspace state at all.
- **The Release gate opens every staged feature but the Nova Assistant.** The
  catalogue in Settings → Features keeps labelling each capability with the stop
  that exposes it, and Debug builds keep exposing everything, so the labels stay
  meaningful after the train reaches its stable stop.

### Fixed

- **Import read the type the screen allowed, not the file that was chosen.** A
  package whose name did not look like the accepted kind was refused before its
  bytes were looked at, and a hand-off could be answered with a refusal for a
  file the user never picked. The chosen document is now the one that is read;
  the destination screen no longer decides which file arrives.
- **`Scripts/ci/version_claims.py` counted 17 of 18 features.** A `case` line
  that declared its features before a trailing comment
  (`return [.smartWorkspace]   // …`) was skipped by an end-anchored match, so
  the honest page's "N on · M ahead" header was computed from a short list.
  The comment is stripped before matching.

### Known limitations

Carried in `ReleaseBlockerRecord.registry` and shown in the Compatibility Lab:

- **In-app installation has no available mechanism.** *(Low, accepted — ZynSign
  builds the OTA manifest, the install link, and the QR and hands off; it never
  claims an install, and Settings → Installation keeps the typed assessment.)*
- **Device and iOS matrices need physical-device confirmation.** *(Medium,
  open — the Lab executes the rows of the device it runs on and records every
  other row as not run; the private matrix in
  `docs/releases/private-testing.md` is where the rest are closed.)*
- **Signing scenarios stop at preparation without signing material.**
  *(Medium, open — scenarios verify the reproducible preparation stages;
  executing a real signature needs an identity and a profile on the device.)*
- **Performance figures measured on a simulator are not device figures.**
  *(Low, accepted — a simulator row is labelled as such and never compared
  against a device benchmark.)*

### What this release deliberately does not claim

- **No install.** ZynSign does not install applications on a device, pair with
  one, enable JIT, or mux a debug server. Those stay recorded limits, not
  features waiting on a bug fix.
- **No device verification.** Nothing in this release was exercised on a
  physical device by the process that wrote these notes. The candidate record in
  `docs/releases/private-testing.md` says so; the tag waits for it.
- **No cloud sync and no off-device measurement.** `AnalyticsPolicy.isEnabled`
  is `false` on every path, the endpoint is `nil`, and the sent-event count is
  zero.
- **No trust claim.** Verification says an artifact is internally coherent — not
  that it is authorized by Apple, notarized, or installable.
- **No App Store distribution.** Every build is sideload or TestFlight only.

### Testing

New unit tests: `ExportsCenterModelTests` — listing and ordering, a missing
artifact staying listed and disabling artifact actions, an empty catalog versus
a filtered-to-nothing query, the verification/availability/date filters,
verification replacing a row only when it actually ran, a failed verification
reporting without changing the row, delivery marking, deletion scope (the
deleted record and its file only), and the export↔operation link. **Their
results belong to CI** — the `Build and test (Xcode)` job is the judge, and this
note claims nothing about them until it has run.

Host audits, run on the machine that produced this note:

| Audit | Result |
|---|---|
| `Scripts/ci/version_claims.py` | `v1.0.0 · build 10 · 17 of 18 staged features · 3 never` |
| `Scripts/ci/docs_check.sh` | 86 pages, 0 errors, 0 warnings |
| `Scripts/audit_release_gating.py` | 18 of 18 staged features wired, 0 deferred |
| `Scripts/audit_presentation_ports.py` | 4 of 4 presentation ports installed; verified to fail when one is removed |
| `Scripts/audit_crash_surface.py` | 2 baselined constructs, both justified (`AppleSigningKeyResolver` field-key bridging) |
| `Scripts/audit_accessibility.py --strict` | no hard-coded colour, no undersized control |
| `Scripts/audit_navigation_stack.py` | no pushed view opens its own container |
| `Scripts/audit_identity_stability.py` | every `Identifiable.id` is stored, none minted per read |
| `Scripts/audit_regression_coverage.py` | every named behaviour maps to a test that exists |
| `Scripts/audit_design_tokens.py --check` | baseline unchanged |

Device rows: **none.** No device class or iOS version has run the Compatibility
Lab against this build. No row is filled in from a simulator run or from a wish.
