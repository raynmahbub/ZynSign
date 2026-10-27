# Release notes — v1.0.0

## [1.0.0] — stable · the whole app, switched on

Market `1.0.0` build `9` (`CFBundleShortVersionString 1.0.0`,
`CFBundleVersion 9`), tag `v1.0.0`. Release train `.stable`: this stop switches
on every staged feature the train has carried to here — **Entitlements Studio**,
the **Developer Identity Center**, **Mission Control**, the **installation
delivery hand-off**, the **local activity journal**, the **Installation
Workspace**, the **Performance Engine** dashboard, the **Smart Workspace**, and
the **Signing Health Score**. One feature is still ahead: the **Nova Assistant**
ships at `.nova1` (`v3.0.0-nova.1`), and the honest limitations page says so.

`1.0.0` is not a rewrite. Every surface below has been compiled and tested since
the alpha that introduced it; this stop is the one that stops hiding them. The
stops between `.alpha2` and here — `beta3`, `beta4`, `rc1`, `rc3` — carried
fixes only, which is why they add no feature of their own.

### Added

- **The Export Center — every signed artifact, reachable again.** Signing wrote
  a container into export storage and recorded it; until now that record was
  reachable exactly once, from the signing result that produced it, until the
  screen closed. `ExportsCenterView` lists the catalog newest first with its
  verification, availability, size, and delivery state, filters it by
  verification, availability, and date, and offers verify-again, share, reveal
  in Library, copy reference, and delete on each row. The detail screen shows
  the artifact's provenance — the signing operation that produced it, when the
  journal still holds one — and its last independent verification with every
  finding. Honest states, not empty ones: an artifact whose bytes are gone stays
  listed and marked unavailable; a verification that could not run says so and
  changes no row; a deletion names what it removed and leaves the application
  and the history untouched. Reachable from Home, the Library toolbar, a signing
  result, and Settings → General.
- **Signing History — the runs that produced nothing.** `SigningHistoryView`
  gives the signing journal its own screen: every operation, successes,
  failures, and cancellations, filtered by outcome, verification, and date. A
  failed run is a first-class row that opens the same detail screen the Export
  Center links to — the stage it stopped at, the category, the fixed-language
  explanation, and the technical detail behind a disclosure. Clearing the
  journal removes history and nothing else. Reachable from Settings → Signing
  and from the Export Center.
- **Entitlements Studio (`.alpha3` → on)** — read-only entitlements and profile
  compatibility for an application, from its detail screen, its signing run, and
  Settings → Diagnostics.
- **Developer Identity Center (`.alpha3` → on)** — teams, identity health,
  certificate and profile inspectors, the relationship graph, conflicts, an
  expiration forecast, and the identity timeline, with the recommended identity
  surfaced on the signing screen.
- **Mission Control (`.beta1` → on)** — Home → Refresh Everything refreshes
  sources, re-reads the library, and prunes caches in one pass, then reports what
  completed and what was unavailable. Re-signing is never auto-triggered.
- **Installation delivery hand-off (`.beta1` → on)** — Sign → Deliver… produces
  the OTA `manifest.plist`, a percent-encoded install link, an on-device QR, and
  step guides for OTA, MDM, and host tooling. HTTPS only; ZynSign uploads
  nothing, hosts nothing, probes nothing, and learns no install outcome.
- **Local activity journal (`.beta1` → on)** — a bounded JSONL journal of
  category, fixed slug, outcome, and time, with live counts, recent activity,
  one-tap clear, and export. Off-device measurement stays `false`, the endpoint
  `nil`, and the sent-event count zero.
- **Installation Workspace (`.beta2` → on)** — readiness checklists, the
  installed applications library, delivery attempts and confirmations,
  installation history, the artifact relationship view, and storage awareness.
  In-app installation of arbitrary IPAs remains unavailable on every path; the
  workspace says which requirement is missing instead of failing anonymously.
- **Performance Engine dashboard (`.beta2` → on)** — Settings → Advanced →
  Performance: library and index counts, cache statistics by category, the
  search index's status, benchmarks with regression detection, and manual
  optimization.
- **Smart Workspace (`.rc2` → on)** — Home becomes the command center: a
  daypart greeting, widgets ordered by what the person actually opens, Continue
  Last Session, and the Nova Assistant's suggestions when that stop arrives. Its
  cards open the tab that owns the work; the classic dashboard's import doors
  stay exactly where they were.
- **Signing Health Score (`.stable` → on)** — a pre-sign assessment that
  predicts whether an identity, profile, and bundle combination will succeed
  before the pipeline runs, shown on the signing screen.

### Changed

- **A presentation port the shell never installs is now a CI failure.**
  `Scripts/audit_presentation_ports.py` reads every `*Presentation` value in
  `Presentation/` and requires `RootView` to install each one. A port left
  uninstalled hands every caller the default no-op: the surface exists, the
  tests pass, and nothing can reach it. That is precisely how the Export Center
  stayed invisible while its use case, model, and detail screen were complete and
  tested. A port that is deliberately not installed must be recorded in
  `Scripts/ci/presentation-port-deferrals.txt` with its reason, and the audit
  fails once that deferral has been repaid.
- **The Release gate opens everything but the Nova Assistant.** The catalogue in
  Settings → Features still labels each capability with the stop that exposes it,
  and Debug builds keep exposing everything, so the labels stay meaningful after
  the train reaches its stable stop.
- **The Library can be opened at one application.** `ApplicationLibraryView`
  takes an `initialRecord`; the Export Center's *Reveal in Library* uses it to
  switch tabs and push that application's detail screen, then clears the request
  so a later visit to the Library is an ordinary visit.

### Unchanged, deliberately

- In-app installation, device pairing, JIT, mux, and off-device measurement stay
  unavailable. `1.0.0` is the point at which those are *recorded limits* rather
  than prerequisites, and `docs/product/WHAT_DOES_NOT_EXIST.md` lists each one
  with what ZynSign says and does instead.
- Nothing here has been device-verified in this checkout. The private test
  matrix in `docs/releases/private-testing.md` remains the gate between a tagged
  source tree and a public release.
