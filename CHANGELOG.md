<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `docs/releases/version-strategy.md` for the pre-1.0 progression and
`docs/releases/private-testing.md` for the private → public gate.

> **Distribution:** every build is sideload / TestFlight only — no App Store
> submission and no install claim (see `docs/architecture/installation-compatibility.md`).

## [Unreleased]

### Added

- **DER entitlements are read, not just written.** `DEREntitlementsSerializer`
  has always been able to emit Apple's slot-7 form; nothing could read it back,
  so a signature carrying only DER claims was reported as *unknown, not empty* in
  the Entitlements Studio. `DEREntitlementsDecoder` closes that gap: it parses
  the same grammar the encoder writes — a DER `SET` of `SEQUENCE { key, value }`
  with UTF8String, BOOLEAN, INTEGER, OCTET STRING, SEQUENCE (array) and SET
  (dictionary) values — back into the same typed claim set. It is strict by
  design and refuses rather than guesses: indefinite or non-minimal lengths,
  non-canonical booleans, non-minimal or over-wide integers, duplicate keys,
  trailing bytes, unknown tags, and any tree past the configured depth, node,
  string, data or collection bounds. `EmbeddedSigningMetadataInspection` now
  records **which slot** the claims came from, the Studio names it, and a
  malformed DER blob is still `malformed` — never silently empty and never a
  partial set. A decoded claim set is data; no signature integrity, Apple
  authorization or device trust is inferred from reading it.

- **Refresh reminders, off until you ask.** The studio can post one local
  notification per build on the day that build should be signed again — the
  same action date the calendar draws, nine in the morning, soonest first and
  capped at twelve. Work that is already due gets none, because the queue is on
  screen and a notification about a past date is noise; a run with no expiry
  gets none, because a deadline invented from nothing is a promise nobody made.
  Identifiers are stable and namespaced, so a second read replaces a reminder
  rather than doubling it. The switch is off by default, turning it on is the
  only path that asks the system for permission, and a refusal is accepted
  silently — the countdowns stay. Nothing is transmitted: a notification is this
  device posting a sentence to itself. See `docs/architecture/sideloading.md`.

- **A refresh calendar for the next two weeks.** The Sideload Studio answers a
  second question beside "what is late": *when is my week busy*. Every lease is
  projected onto the day it should be signed again — its expiry minus the lead
  its own account implies, so a seven-day personal-team build acts on day five
  and a year-long membership build three weeks before its anniversary — and the
  fourteen days are drawn as one strip, empty days and all. Work that is late
  lands on today rather than in a negative column; a lease whose run recorded no
  expiry is listed beside the strip instead of being given a deadline nobody
  agreed to; a lease past the window is counted rather than squeezed into the
  last cell. The whole window can be copied as plain text — app, day to re-sign
  by, the expiry that date came from, and the account that signed it — so a plan
  can leave the screen. The calendar is built once per read beside the plan and
  the usage rows, so the strip, the queue, and the copied schedule describe one
  instant. See `docs/architecture/sideloading.md`.

### Changed

- **Native XCTest evidence stays downloadable after a pass and after a failure.**
  The Build and Release macOS jobs upload the `.xcresult` bundle and the test
  logs as `xctest-results-<run-id>-<attempt>`, kept for 14 days. The job
  summary records the Xcode version, the simulator destination, and a concise
  count. DerivedData, signing certificates, private keys, and provisioning
  profiles are not in that artifact. A missing bundle warns and does not fail
  the job. See `docs/development/continuous-integration.md`.

- **The sideloading rows are measured, not assumed.** `Settings → Sideloading`
  passed `buildCarriesLocalTunnelEntitlement: false` as a constant, so every
  build said the same thing about the entitlement that decides whether a device
  session can exist — true of an App Store build, a guess about a self-signed or
  enterprise one. `ProcessEntitlements` now reads the running binary's own
  signature once at composition (`SecTaskEntitlementReader`), and the screen
  shows three distinct states: **granted**, **absent** (read, and not there), or
  **not established** (nothing readable — preview, simulator). iOS exposes no
  process-entitlement query (the macOS `SecTask` API is absent from the overlay),
  so the reader parses the app's **own embedded signature** with the same
  Mach-O/slot decoder the Entitlements Studio uses — the same claims the system
  would consult. `nil` never
  collapses into `false`: an unmeasured build stays unsupported, but its note
  says the signature could not be read instead of claiming the entitlement is
  missing. `get-task-allow` keeps the Studio's rule: `declaresGetTaskAllow`
  reports the claim's presence, `allowsDebugging` reports its value, so a
  profile that declares `false` is never read as one that declares nothing. A build that carries the entitlement lights the rows up on its own
  and still needs a pairing record and a composed transport — and what a device
  does with the session remains the device's answer. See
  `docs/architecture/sideloading.md`.

### Fixed

- **A capacity failure no longer looks like a lint failure.** `Lint and format`
  ran on `macos-15` only to `brew install` SwiftLint and SwiftFormat, and when
  GitHub's hosted macOS pool was short a runner the job ended red with the
  annotation *"the job was not acquired by Runner of type hosted"* — not one
  step executed, nothing linted, nothing disproved — beside a green Xcode build.
  Neither tool needs Xcode: `Scripts/ci/lint.sh` and `Scripts/ci/format.sh`
  already run both from their published Linux images when no binary is
  installed, so the job now runs on `ubuntu-24.04` with the same pinned
  `.swiftlint.yml` and `.swiftformat` rule sets and the same verdict, leaving
  the macOS pool to the two jobs that genuinely need it. The retry path for a
  run that still cannot get a machine is written down in
  `docs/development/continuous-integration.md` — re-run the failed jobs on the
  same commit; a shortage is never a test result.

## [3.0.0-nova.1] - 2026-10-28

> `v2.0.0` was scheduled as depth and fixes and introduced no gate of its own,
> so the train moves to the first stop that switches another feature on and
> carries that work here. With this stop every staged feature the train has ever
> carried is visible: **18 of 18**. The three *never* rows are unchanged and
> still explained in `docs/product/WHAT_DOES_NOT_EXIST.md`.

### Added

- **Nova Assistant — the last staged feature, now on.** Nova reads the stores
  the rest of the app reads — identities, profiles, the library, the signing
  journal, and the backup record — and says what needs attention before it
  becomes a failure: an identity or a profile that has expired, or that expires
  within fourteen days (urgent inside three); a library with applications but
  no identity to sign them; identities but no profile; two applications sharing
  one bundle identifier; an application no valid profile covers, one a profile
  already covers, or one that was signed successfully before; and a backup that
  is at least a week old. Six suggestions at most, urgent first and then by
  title, because the top of the list is the part worth reading; every one names
  the screen that owns the work and opens it, and **nothing is applied, queued,
  scheduled, or signed on the person's behalf.** It runs entirely on device:
  rule-based, no model, no network client, no telemetry, no text of yours
  leaving the process. Visible on the Smart Workspace whenever it has something
  to say.
- **Zeus: the theme the app now opens on.** Violet lightning over deep indigo —
  a `#1B1140 → #4C2A9E → #8B5CF6` hero gradient, a violet accent, and cyan
  highlights on the surfaces that carry one — shipped through the existing
  theme catalog, so Settings → Appearance previews it like any other theme and
  nothing about signing depends on it. A stored theme is never rewritten: every
  earlier theme stays selectable and resolves exactly as before. The Sideload
  Studio's own palette is the same family, so the refresh countdown and the
  rest of the app no longer disagree about what the app looks like.
- **Sideload Studio: the seven-day clock, read from the journal.**
  Every delivered signing run already records the profile and certificate that
  signed it; `SideloadLedger` reads those records and derives one lease per
  application — the earlier of the two expiry dates, the account the profile
  belongs to, and how many days are left — without storing a second list of
  what is installed. A free personal team's week, a paid membership's year, and
  an in-house profile's year are read from the profile's own classification and
  lifetime, and a run whose account cannot be established is left without one
  rather than guessed at. `SideloadAccount` publishes the limits the studio
  plans with — three apps at once and ten App IDs a week for a free team, a
  hundred registered devices for a membership — and names the services a
  personal profile cannot carry. The screen leads with the build that stops
  launching next, puts the due and expired builds in a refresh queue, and hands
  one to the ordinary signing flow; a build whose application has left the
  library says so instead of offering a button that cannot work. The countdown
  is the profile's date, never a claim that the app is installed on a device.
  A new studio surface — midnight-to-violet hero, gradient rings, account
  cards — sits beside the existing themes rather than replacing any of them,
  and Home gains one row that says what stops launching next, hidden until the
  journal has something to report. See `docs/architecture/sideloading.md`.
- **Sideloading: package edits, a device bridge, and guest containers.**
  `SideloadPackageEditor` rewrites a package inside the signing working copy —
  Info.plist overrides, nested-code and URL-scheme removal, dylib injection
  into header padding — before the first binary is signed, because the
  CodeDirectory hashes what it rewrites; an image with too little padding, a
  universal binary, or an existing signature is refused with the arithmetic.
  `DeviceBridgeService` speaks the pairing, mutual-TLS, AFC, and
  `installation_proxy` layers to a connected device and reports the one
  entitlement it still needs instead of failing anonymously. `GuestContainer`
  prepares an app to run inside ZynSign's process instead of being installed:
  its own `Applications/<BundleID>/` container with `Tweaks/` and `Data/`, a
  Mach-O file type `dlopen` will map, and a launch plan whose every step names
  its prerequisite. Blocks are facts (FairPlay encryption, universal binary,
  extensions, a watchOS bundle, a missing loader), warnings are preferences
  (JIT, Metal, a newer minimum OS). The launch itself needs a device and is
  not claimed. See `docs/architecture/sideloading.md`.

### Fixed

- **A package and a certificate are read by their content, not by their name.**
  The document picker's own answer was being overruled before the file was
  copied. The pre-import checks refused a package whose first four bytes read
  through a provider did not spell a ZIP container — including when the bytes
  could not be read at all — so a `.ipa` or `.tipa` that Files had not
  materialised yet, or whose provider answered a partial read, was rejected
  before staging and never reached the archive boundary. They now police the
  resource only (not a directory, not empty, inside the copy ceiling) and leave
  content to the copy: a package-named document is staged and the archive
  boundary reads it, while a document under any other name is accepted when its
  bytes begin a container, which is what makes a package that AirDrop or a
  browser renamed importable. The copy itself gained the route it was missing —
  a coordinator that cannot run, reports a provider error, or copies nothing is
  retried directly on the same bytes rather than failing the import — and a
  copy that moved no bytes is reported as unreachable instead of as a damaged
  archive. The certificate reader no longer refuses a file by its extension at
  all: a `.p12` renamed to `.cer`, saved without an extension, or handed over
  as text in Base64 (bare or between `BEGIN`/`END` lines) reaches the password
  form, a text file that was renamed to `.p12` is refused for what it holds,
  and a failed coordinated read falls back to reading the document directly.
  Zero-size observations are withdrawn for documents the provider has not
  delivered, so a download in progress is no longer reported as an empty file.
  A dropped item whose declared type cannot be loaded as a file now falls back
  to the file URL it also carries, and the Microsoft PKCS#12 type declares the
  `pfx` tag it was missing.

- **A file the person chose is imported, whatever the screen is doing.**
  Two silent refusals sat between the document picker and the importer, and
  both were about presentation state rather than about the file. The Import
  Hub discarded a whole selection — and asked the person to choose again —
  when the presented-controller chain took longer than eight seconds to report
  idle after the picker closed; it now receives the files the moment the
  picker answers, and a package the importer cannot read is refused on its own
  item with the reason. The Certificates password form discarded a `.p12` that
  had already been read successfully when the platform refused to present the
  sheet twice; the bytes now stay pending and *Import Certificate…* presents
  the form again instead of asking for the file. Both pickers are armed and
  then *checked*: a `.fileImporter` binding the platform refused stays `true`,
  so every later tap disappears into "already presenting" — a presentation
  that does not appear is now reset, retried once, and reported when it still
  fails. The shell's queue follows the same rule: a hand-off is presented after
  a short best-effort settle rather than parked until some sheet that is not
  coming is dismissed, a shell sheet that never appears is detected by its own
  appearance report and asked for again, and the Import Hub's restore gate is
  released on every path out of restoration, so a file received during a
  launch restore can no longer sit at "waiting" with nothing to read.

- **The weekly sweep opens its repair pull request again.** The
  `04-maintenance.yml` repair step built the PR body with two backslashes
  before each markdown backtick. bash reads `\\` as one literal backslash and
  then starts a command substitution on the backtick that is now unescaped, so
  the step tried to *run* `04-maintenance.yml`, `docs/internal/`,
  `.swiftformat` and `MARKETING_VERSION` and the job died with exit 127 —
  after the metrics report, the formatting pass and the artifact upload had
  already succeeded. The body took one backslash per backtick, and the step now
  reaches the path it was written for: it stages the branch and, in a
  repository where Actions may not open pull requests, reports that as the
  warning it is instead of a failure. The summary card carried the same
  escaping mistake and printed "is a directory" for `docs/internal/`; it now
  renders the row. `Scripts/ci/workflow_shell_check.py` keeps the class of
  mistake out: it parses every workflow `run:` block with `bash -n` — which a
  YAML edit that breaks quoting should never survive — and refuses a backtick
  with two backslashes in front of it, which `bash -n` cannot see. The
  Repository hygiene job runs it on every pull request.

- **The two stops that promised a screen now tell the truth — one retired, one
  wired.** `ReleaseFeature.batchSigning` is gone: the `v0.9.0-beta.3` row named
  a behaviour the signing queue already ships (**Queue Selected for Signing…**
  applies one identity and profile to a whole selection, one job at a time,
  journalled by `SigningOperationCenter`), so the stop would have added a second
  name for a shipped behaviour or, if wired to `BatchSigningCoordinator`, a
  second signing path. The gate was never exposed, so no user loses anything;
  the coordinator and its `BatchSigningCoordinatorTests` stay as the tested
  sequencer they are, with nothing constructing them. The other stop is real:
  **Signing Health Score** now renders on the Sign screen as
  `SigningHealthScoreCard`, built from `SigningHealthAssessment` over the
  identity, profile and bundle the user has selected — a prediction with its
  findings, recomputed when the selection changes, and never a gate (the
  pipeline remains the authority). `Scripts/ci/release-surface-deferrals.txt` is
  empty and `Scripts/audit_release_gating.py` now reports 18 of 18 staged
  features wired, 0 deferred. See `docs/releases/release-train.md` and
  `docs/product/WHAT_DOES_NOT_EXIST.md`.

- **Batch Signing is a duplicate of a shipped behaviour, and the record now
  says so.** The train schedules it at `v0.9.0-beta.3` as if it were missing.
  It is not: **Queue Selected for Signing…** applies one identity and profile to
  a whole selection and `SigningQueue` runs those jobs one at a time
  (`maximumConcurrentJobs = 1`), journalled by `SigningOperationCenter` — that
  is what signing a set with one configuration means, and it shipped in
  `v0.1.0-alpha.2`. The only code carrying the stop's name is
  `BatchSigningCoordinator`, which nothing constructs and which predates the
  operation center: it takes the raw pipeline, names its own outputs, and writes
  its own history records, so a surface built on it would be a second signing
  path that delivers, verifies and journals differently from every other signed
  artifact. Its documentation said the signing queue used it; the queue does
  not — it runs through `SigningOperationExecutor`. The duplication is recorded
  in the deferral file and on the product page, and the coordinator's own header
  now states that nothing constructs it and why a surface must not be built on
  it before the duplication is retired.
- **A batch run no longer reports a refused package as delivered.**
  `BatchSigningCoordinator` read only the signing engine's return value, not its
  status — and the engine reports a refusal as a returned result rather than a
  thrown error. A package the pipeline refused was therefore recorded as a
  success with an output file name, nothing on disk, and a `succeeded` step in
  the summary: the one claim a batch result must never make. The step now reads
  the status, refuses with the failing stage and the pipeline's own detail, and
  leaves the remaining entries to run. The coordinator also depends on a
  `BatchSigningStep` port rather than the concrete pipeline, so the sequencing
  rules are exercised by `BatchSigningCoordinatorTests` — the suite this
  sequencer never had, which is how the defect survived.
- **Two release stops no longer promise a screen that does not exist.** The
  train schedules Batch Signing at `v0.9.0-beta.3` and Signing Health Score at
  `v1.0.0`, and **Settings → Features** labels both `Planned · <tag>` — but
  nothing in the app referenced either: `BatchSigningCoordinator` is a sequencer
  no screen constructs, and `SigningHealthScore` / `SigningHealthAssessment` are
  tested values nothing reads (the
  always-on health card on an application's detail screen is the older
  `SigningDiagnosticsAnalysis`, a different feature). Both stops would have
  reached users having changed nothing they could see. The gap is now recorded
  where a reader looks for it — `docs/product/WHAT_DOES_NOT_EXIST.md` and
  `release-train.md` name both features, their stops, and what is missing — and
  `Scripts/audit_release_gating.py` enforces the rule from now on: every
  `ReleaseFeature` is either referenced by the app's own source or listed in
  `Scripts/ci/release-surface-deferrals.txt` with a reason, and a deferral that
  has been repaid fails the build, so the list cannot outlive the gaps it
  describes.
- **Sideloading is in the capability catalogue.** The `Settings → Devices →
  Sideloading` screen was reachable in every build — Debug and Release alike —
  while no registry named it: it was not a `CoreFeature`, not a
  `ReleaseFeature`, and not an `UnsupportedFeature`, so **Settings → Features**
  could not show it and the honest-limitations accounting could not count it.
  It is registered as `CoreFeature.sideloading`, which is the right registry:
  the screen *is* the explanation, so the build that cannot install is exactly
  the build that must show why. The comment at the call site says so, and
  `FeatureCatalogTests` now fails if anyone gates it behind a release stop.
- **The repository no longer names a release it never cut.** `v0.1.0-alpha.3`
  was declared, drafted and then rewound before it shipped, but the draft
  outlived the rewind: a dated `[0.1.0-alpha.3]` changelog section, a release
  notes page, and a row in the in-app version history all described ten
  features switched on in build 2 — while the train sat at `v0.1.0-alpha.2`
  (build 8), no `v0.1.0-alpha.3` tag existed, and no such release was ever
  published. The product pages drifted the other way, still describing
  `v0.1.0-alpha.1`. All of them now read from the train: the phantom section,
  notes page and version-history row are gone, the two product pages state
  `v0.1.0-alpha.2` with its real counts (19 staged, 8 reachable in Release, 11
  ahead, 3 never), and `Scripts/ci/version_claims.py` fails the documentation
  job when any page, note, changelog section or version-history entry names a
  stop the train has not reached or a build number the project does not carry.
  `VersionHistoryCatalogTests` holds the in-app list to the same rule.
- **A nested framework no longer stops the seal.** The resource walk reported a
  nested framework — or a bundled dynamic library — and the application's seal
  also named that same path as nested code, and a seal told about one path
  twice refuses it: signing such a package stopped at resource sealing. The
  walk now leaves every path the caller states as nested code to its own seal,
  while still listing the directory that holds it, so each target is sealed
  exactly once.
- **An injection plan counts its own signature command.**
  `DylibInjectionPlanner.plan` reserved the sixteen bytes `LC_CODE_SIGNATURE`
  needs when it checked for room, then reported a command table without them,
  so `resultingSizeOfCommands` and the remaining padding disagreed with the
  bytes an injection writes.
- **An injected load command is stamped the way the linker stamps it.**
  `LC_LOAD_DYLIB` and `LC_LOAD_WEAK_DYLIB` carried a zero timestamp; the
  platform's own linker writes `2`, and an image that disagrees with every
  other one on the device is a difference with no purpose.
- **A guest with no tweaks is no longer warned about.** `GuestContainer`'s
  warnings describe the guest. Whether a tweak was staged is a fact about the
  staging plan, so a guest with nothing staged is the ordinary guest and says
  so by saying nothing.
- **Importing no longer freezes the interface.** `ImportHub` runs each item's
  staging, examination, and the serialized admit in detached tasks, so the copy
  loop, the archive reads, and the staged artifact's SHA-256 pass stop running on
  the main thread — the stall the platform watchdog measures, and the reason a
  long import looked hung.
- **A file still downloading in Files is not "empty".** The new
  `UbiquitousContentWait` asks iCloud for a placeholder's bytes and waits,
  bounded, before anything reads them; package staging and the `.p12` read share
  one policy. A dataless certificate reported "empty file" and a dataless package
  reported "not an archive", and neither was the file's fault.
- **A `.p12` says why it was refused.** The importer separates an empty,
  oversized, or non-container input and reads `SecPKCS12Import`'s status as a
  cause, so a wrong passphrase, a foreign format, and an unexplained failure each
  get their own message and their own recovery advice
  (`SigningIdentityFailure.invalidPassphrase`, `.unsupportedContainerFormat`,
  `.containerImportFailed`). An imported identity is also no longer refused for a
  key class only the Keychain item's dictionary was asked to report — the
  resolver reads it from the key handle.
- **Dropping a file from Files works.** `public.file-url` joins the drop
  target's accepted types (a file URL conforms to `public.item`, not
  `public.data`), the receiver reads a provider through whichever route it
  actually offers, and a drop nothing can be read from is recorded as a refusal
  instead of vanishing without a word.
- **One damaged registration no longer locks the identity store.**
  `KeychainIdentityRegistry.remove` judges every item on its own, so an identity
  can still be forgotten — and re-imported — while an unreadable record stays
  fail-closed for the reads that must not guess.

### Changed

- **The certificate sheet types itself, and nothing is ignored silently.** The
  password field holds focus from the first frame, Return submits, an eye toggles
  reveal; a multi-file selection and a file chosen mid-import are both answered
  with what to do next. `Info.plist` now declares the types its document entries
  already referenced (`com.apple.itunes.ipa`, `com.apple.mobileprovision`,
  `com.rsa.pkcs-12`, `com.microsoft.pkcs12`) and owns `io.zynsign.tipa`, and a
  file handed to ZynSign that is none of the accepted kinds lands in the Import
  Hub as a refusal that names what ZynSign does take.

## [1.0.0] - 2026-10-28

> The train's last stops before this one carried no new feature of their own:
> `v0.9.0-beta.3`, `v0.9.0-beta.4`, `v1.0.0-rc.1`, `v1.0.0-rc.2` and
> `v1.0.0-rc.3` were fixes-only rehearsals of the surfaces below. `1.0.0` is the
> stop that switches them on together, and nothing in it is new code that has
> not been compiled and tested since its alpha.

### Added

- **The Export Center.** Every signed artifact ZynSign holds is now one list:
  newest first, filtered by verification, availability, and date, each row
  carrying the application it came from, the bytes it holds, its last
  independent verification, and whether it has been handed to the system.
  `ExportsCenterView` presents the catalog `ExportCenter` already kept —
  verifying an artifact again, sharing it, revealing its source application in
  the Library, or deleting it — and the detail screen links each artifact back
  to the signing operation that produced it. The list is a projection of the
  catalog, never an edited copy: an artifact whose file is gone stays listed and
  says so, a failed verification is reported and changes no row it did not
  measure, and deleting an export never touches the imported application or the
  signing history beside it. Reachable from Home, the Library toolbar, a
  signing result, and Settings.
- **Signing History.** `SigningHistoryView` is the journal's own screen — every
  run of the signing pipeline, including the ones that produced no artifact.
  A failure is a first-class row: the stage it stopped at, the outcome it
  recorded, and the same detail screen the Export Center links to. Without it a
  failed signing left no trace the user could reach, because only successes put
  a file in export storage. Filter by outcome, verification, and date; clear
  the journal without touching a single artifact.
- **Entitlements Studio.** Read-only entitlements and profile compatibility
  reachable from an application's detail screen, its signing run, and
  Settings → Diagnostics.
- **The Developer Identity Center.** Teams, identity health, certificate and
  profile inspectors, conflicts, expiration forecast, and the identity timeline,
  with the recommended identity surfaced on the signing screen.
- **Mission Control.** Home → Refresh Everything: repository refresh, a library
  re-read, and cache cleanup in one pass, with a report of what completed and
  what was unavailable.
- **Installation delivery hand-off.** Sign → Deliver… builds the OTA manifest,
  the percent-encoded install link, an on-device QR, and the step guides for
  OTA, MDM, and host tooling. ZynSign uploads nothing, hosts nothing, and never
  learns an install outcome; `InstallationCapabilityAssessment` keeps in-app
  installation unavailable on every path.
- **The local activity journal.** Settings → Analytics records category, fixed
  slug, outcome, and time in a bounded on-device journal, with live counts,
  recent activity, one-tap clear, and export. Off-device measurement stays off:
  `AnalyticsPolicy.isEnabled` is `false`, the endpoint is `nil`, and the counter
  reads zero.
- **The Installation Workspace.** Delivery readiness checklists, the installed
  applications library, delivery attempts and confirmations, installation
  history, the artifact relationship view, and storage awareness — from
  Settings → Devices, a signing result, and the Smart Workspace's Install Health
  card.
- **The Performance Engine dashboard.** Settings → Advanced → Performance shows
  the library and index counts, cache statistics by category, the search index's
  status, benchmarks with regression detection, and manual optimization.
- **The Smart Workspace.** Home becomes the command center at `v1.0.0-rc.2`:
  a daypart greeting, widgets ordered by what the person actually opens,
  Continue Last Session, and the Nova Assistant's on-device suggestions when
  that feature ships. The classic dashboard's import doors stay where they were;
  its counts, favourites, and recently imported summaries move into the widgets
  that already carry the same facts.
- **Signing Health Score.** Pre-sign compatibility assessment predicts whether an
  identity, profile, and bundle will succeed before the pipeline runs.

### Changed

- The release train reaches its first stable stop. Every staged feature except
  the Nova Assistant — which ships at `v3.0.0-nova.1` — is switched on in a
  Release build; `Scripts/audit_release_gating.py` reports 18 features wired,
  one still ahead, and the honest limitations page records the limits that stay.
- **`Scripts/audit_presentation_ports.py`** makes the shell's presentation ports
  mechanical. A `*Presentation` value the shell never installs hands every
  caller a silent no-op: the surface exists, the tests pass, and nothing can
  reach it — which is exactly how the Export Center stayed invisible while its
  use case, model, and detail screen were complete. The audit fails on a port
  the shell does not install and on a deferral that has since been repaid.

### Fixed

- **Import reads the file that was chosen, not the one the screen allows.** A
  package whose name did not look like the accepted kind was refused before its
  bytes were examined, and a hand-off could be answered with a refusal for a
  file the user never picked. The chosen document is the one that is read now,
  and the destination screen no longer decides which file arrives.
- **`Scripts/ci/version_claims.py` counted 17 of 18 features.** A `case` line
  that declared its features before a trailing comment —
  `return [.smartWorkspace]   // …` — was skipped by an end-anchored match, so
  the honest page's "N on · M ahead" header was computed from a short list. The
  line comment is stripped before matching, and the reason is recorded in the
  code.

## [0.1.0-alpha.2] - 2026-10-05

> The seven-tab bar the section below this one describes was this train's own
> interim shape; the five-tab contract in **Changed** is the one this release
> ships.

### Added

- **Storefront, the new default look.** `AppThemeCatalog` gains the Storefront
  theme — a signature gradient (`#FF3D71 → #FF6A3D → #FFB13D`) over deep glass,
  dark first, with the flame accent on every control — and it is what a fresh
  install opens on. The five themes that shipped before stay selectable under
  Settings → Appearance → Theme, so an update never takes an appearance away
  from the user who chose it.
- **Liquid glass, everywhere, with one switch.** `ZGlass` is the single layer
  that decides what a glass surface is, and every glass surface in the app
  asks it: cards (`ZCard`), the shell's tab bar, toolbars and bars, toasts,
  and the Home command-centre card. On iOS 26 the surfaces render with the
  platform's own `glassEffect` — real refraction, real specular edge — and
  pre-26 systems get the ultra-thin material with a diagonal highlight, the
  same recipe the card system shipped with. The preference
  (`Settings → Appearance → Liquid Glass`) now defaults to **on**; turning it
  off resolves every surface to its flat system material in one tap. Nothing
  else moves: the toggle never changes what the app does.
- **The signing workflow opens.** This release train's stage switches on its
  three features — Smart Sign, the Professional Signing Queue, and Intelligent
  Signing Presets — and they arrive with their surfaces: queue badges on the
  Library tab, per-job controls, live stage progress, and preset planning.

### Changed

- **The main screen draws exactly five tabs.** Home, Library, Store,
  Downloads, and Settings — the storefront order. Files was the sixth tab the
  shell cut to keep every target comfortable; the browser itself moves nowhere,
  it is a row in Settings → Browse and one from the Store's downloads, and a
  saved Files landing preference migrates to the Library instead of pointing at
  a tab that no longer exists. `ShellSection.tabCount` pins the number, and
  `ShellSectionTabTests` pins the order, the gate behaviour, and the
  migration. `ShellTabBar` became a floating glass island to match.

### Fixed

- **IPA / TIPA import stops refusing files it can still read.** Three places
  turned "I cannot see the bytes yet" into "this is not a package": an iCloud
  placeholder — the usual shape of a freshly downloaded `.ipa` in the Files
  *Downloads* folder — answered every read with nothing, so
  `SecurityScopedArtifactIntake` observed a non-ZIP signature and
  `ImportPreflight` refused the file. The intake now distinguishes observation
  from ignorance: a short or failed read reports *unknown*, never *wrong
  bytes*; a dataless item is asked to download and given a bounded wait
  (20 seconds, off the main thread only) before anything is judged; and the
  pre-import copy still runs through file coordination, which waits for the
  provider itself. A genuinely empty or wrong-content file is still refused,
  with the same honest reason.
- **A certificate is judged by its content, not its name.** Importing a
  `.p12` that Files, AirDrop, or the user renamed failed in two places that
  only looked at the extension: the manager refused anything that was not
  `.p12`/`.pfx`, and `CoordinatedPKCS12DocumentReader` threw
  `unsupportedFileType` before it opened the file. Both now let content
  decide — a matching name reads directly, an unknown or missing one is
  accepted when it begins with the DER `SEQUENCE` a PKCS#12 container must
  start with, and a format ZynSign knows is not a certificate is still refused
  by name with the clearer message. Pinned by
  `CoordinatedPKCS12DocumentReaderTests`.
- **Settings → Updates no longer crashes.** The tab pushed the Store's Update
  screens — each carrying their own `NavigationLink`s, `.searchable`, and
  `navigationDestination` registrations — into the Settings stack, which owns
  a search field of its own: nested navigation state, the same class that made
  other Settings pages die. Every row now raises its workflow as a sheet over
  a fresh stack of its own, with a Done control, so no store screen can nest a
  controller, search bar, or destination into the host's — whatever those
  views do internally. `PresetsView` had the mirror-image defect the audit
  could not see: it took the `embedsNavigationStack` opt-out but opened its
  iPad `NavigationSplitView` from a size-class branch the flag never gated, so
  a pushed Presets page on iPad nested a second container. The flag now gates
  both containers, and `audit_navigation_stack.py` enforces the class: it
  treats `NavigationSplitView` as the crash-capable container it is, and a
  self-managed view must gate *every* container it opens behind its flag.
- **The App Store tab.** The shell showed five destinations and dropped Store
  and Downloads, because UIKit's own tab bar draws five items and folds the
  rest into a *More* list it **pushes** — and a pushed destination that owns a
  `NavigationStack` (every ZynSign area does) crashes at runtime. Hiding
  destinations was that crash's workaround; the shell now draws its own bar
  (`ShellTabBar`) and gives every destination the release exposes its own tab:
  Files, Library, Home, Store, Downloads, Features, Settings. `ShellSection`
  caps and drops nothing, a saved Store or Downloads landing preference is
  honoured again instead of being folded into Features, and the five-item
  ceiling of UIKit's bar no longer decides what the product shows. Pinned by
  `ShellSectionTabTests`.
- **The Bundle Explorer no longer crashes on open.** `BundleExplorerView`
  (application detail → *View Bundle*, signing → *Explore IPA*) is pushed onto
  the host's stack, and it built `IPAExplorerScreen`, which opened its own
  `NavigationStack` (and a `NavigationSplitView` on iPad). A stack nested inside
  a pushed destination is a runtime crash — the same class that made Settings
  unusable — and this instance was invisible to `audit_navigation_stack.py`
  because the pushed view was fine on its own and the view underneath it was
  not. `IPAExplorerScreen` now takes `embedsNavigationStack` and
  `BundleExplorerView` passes `false`, so details push through the host's
  stack. The audit follows a pushed view's own constructions now, requires a
  real `NavigationStack` use rather than the `embedsNavigationStack` flag that
  contains the word, and honours the opt-out at the call site — three
  regressions were injected and caught while adding it.
- **Import waits on reports, not on a guessed delay.** The Import Hub's file
  picker, the `.p12` password sheet, and the hub raised from Files all slept a
  fixed 400 ms beat before presenting. A presentation requested while another
  controller is transitioning is dropped by UIKit with no error — the tap that
  appears to do nothing — and on a device slower than the guess (a Release
  build, a cold first render) the beat elapses before the animation does, so
  the request was dropped again. `PresentationSettle` now waits for the
  platform's own state (no in-flight transition; a sheet's own appearance
  report, `SheetPresentationReporter`), and `presentAndConfirm` checks that
  something appeared, asking once more when nothing did, instead of leaving the
  tap unanswered. `PresentationSettle.beat` is gone.
- **The private test IPA is always an IPA.** `mode: private-ipa` used to end
  in a warning and an artifact of bare logs whenever the `TEAM_ID` secret was
  absent — the export was skipped and nothing packaged the archive. The whole
  archive-and-package pipeline now lives in `Scripts/ci/private_ipa.sh`. The
  expected deliverable is the unsigned `ZynSign-{tag}-{config}-private-unsigned.ipa`
  — the distribution build, signed by whoever installs it with their own Apple
  certificate, with a `SIGNING.md` in the artifact saying exactly how. A
  `TEAM_ID` secret buys an optional signed ad-hoc export instead, and a run
  that cannot produce any IPA **fails** instead of going green with logs
  alone. The committed ExportOptions template is no longer
  edited in place at export time (the team id goes into a temporary copy), and
  a manual run can skip the unit-test gate (`run_unit_tests: false`) for a
  faster artifact.
- **Workflow annotations tell the truth.** Every GitHub annotation now escapes
  `%`, newlines and carriage returns per the workflow-command spec, carries a
  meaningful title instead of `crystal`, and `select_simulator.sh` emits its
  notices and errors to stderr — they were being swallowed by the caller's
  `$( … )` capture and never reached the checks page. The deprecated Node 20
  `actions/download-artifact` pin was lifted to v7 (Node 24), the floating
  `setup-xcode` tag-object pin was pinned to its commit, every action pin now
  carries its version in a comment, and a manual dispatch no longer cancels
  (or gets cancelled by) in-flight CI runs.
- **One verdict per commit, half the macOS bill.** A push to a branch that
  already has an open pull request now skips its duplicate build — the
  pull-request run of the same commit carries the same gates and the required
  checks — so every PR update stops paying for the same tests twice. The
  Danger job's Homebrew install is cached and skips dependent checks. A new
  weekly `04-maintenance.yml` sweep keeps the repository honest hands-free:
  the full metrics report (Periphery dead-code scan included), the pinned
  SwiftFormat rules applied, a stale README repaired — all opened as one
  reviewable repair PR, never pushed directly.
## [0.1.0-alpha.1] - 2026-10-03 — Auto-generated

### Fixed

- **release:** include current candidate in version history
- **ci:** align release workflow validation
- resolve workflow validation failures
- complete network and persistence hardening

### Maintenance

- harden workflow permissions and PR execution

<!-- Generated from v0.0.2-dev.1..HEAD by Scripts/generate_changelog.py. This entry is not device-verification evidence. -->

## [0.0.1] - 2026-10-01

**The first build.** Market `0.0.1`, tag `v0.0.1`, release train `.horizon` —
the stop the three development rehearsals existed to reach. It switches on no
staged `ReleaseFeature` of its own (`ReleaseStage.horizon.introducedFeatures`
is empty), so what it carries is everything merged since the `v0.0.1-dev.3`
tag: two Settings reachability fixes, and the release machinery that publishes
the notes for the stop being cut. `CFBundleVersion` is 5, assigned by
`python3 Scripts/release_train.py promote` rather than claimed here. Notes:
[`docs/releases/notes-v0.0.1.md`](docs/releases/notes-v0.0.1.md).

> **Gate drift, carried from `dev.3` and recorded again rather than resolved.**
> `certificateStudio`, `provisioningProfileManager`, `appStore` and `downloads`
> still have no live `ReleaseTrain.isAvailable` check at any reachable entry
> point, so a Release build at `v0.0.1` exposes four areas the train assigns to
> `v0.1.0-alpha.1`, `v0.1.0-alpha.2` and `v0.1.0-alpha.3`. `dev.3` shipped with
> that recorded instead of fixed, on the reasoning that re-gating or moving the
> stops after the tag was a product-surface change nobody had asked for; the
> same reasoning holds one stop later, and the decision is still owed to the
> `v0.1.0-alpha.1` cut, where the feature map is written next. What *did* change
> is that this stop is no longer a rehearsal: the drift now sits in a release a
> user can install, so the two options — re-gate the staged *actions* behind
> each surface, or move the four into `v0.0.1` and let the alphas keep what they
> actually switch on — are carried forward with that weight stated.

### Fixed

- **The Security Center was unreachable.** `SettingsSectionCatalog` registered
  all ten sections, and `SettingsSectionCatalogTests` checked every one of
  them — but the Settings index is a `@ViewBuilder` switch over its own
  `SettingsCategory` list, and that list had no `security` case. Nothing else
  in the app links `SecurityCenterSection`, so the row did not exist: the
  biometric application lock, the session timeout, the
  require-authentication-for-sensitive-actions rule, sensitive-data
  visibility, and per-app Lock and Vault were all compiled in, tested, and
  impossible to open. `AppLockOverlay` could therefore never be armed by the
  user, whatever the shipped preference said. The index gains a Security
  category, and each category now records the catalog sections it opens
  (`SettingsCategory.openedSections`) so a registered section with no
  navigation fails `testEveryRegisteredSectionIsReachableFromTheSettingsIndex`
  instead of disappearing quietly.
- **The landing-tab picker offered a tab the bar cannot select.** Settings →
  General listed `LandingTab.tabCases` — all six tab-capable sections — while
  `primaryTabs` renders five, Downloads having yielded its slot to the
  platform ceiling. Choosing Downloads saved the preference, the row kept
  reading *Downloads*, and every launch opened Library, because
  `RootView.visibleSelection` clamped a destination the bar does not render.
  The picker now offers `ShellSection.offerableLandingTabs` and reads through
  `ShellSection.effectiveLandingTab`, which returns the same Library fallback
  launch uses, so the row and the next cold start cannot disagree and a
  preference saved by an earlier build no longer renders as a blank
  selection. Pinned by
  `ShellSectionTabTests.testTheLandingPickerOffersOnlyTabsTheBarCanSelect`,
  `testAFoldedSectionIsNotOfferedAsALandingTab`,
  `testAStoredLandingTabWithNoSlotReadsAsTheTabLaunchOpens`, and
  `testARetiredLandingTabReadsAsLibrary`.

## [0.0.1-dev.3] - 2026-10-01

**Development 3.** Market `0.0.1`, tag `v0.0.1-dev.3`, release train `.dev3` —
the last development stop, and it switches on no staged `ReleaseFeature` of its
own (`ReleaseStage.dev3.introducedFeatures` is empty). What the stop carries is
everything merged since the `v0.0.1-dev.2` tag: the Settings index rebuild, the
shell decision to keep primary navigation open at every stop, the clearer
picker and repository failures behind it, and the release machinery that
publishes the notes for the stop being cut. The `CFBundleVersion` is assigned by
`python3 Scripts/release_train.py promote` rather than claimed here. Notes:
[`docs/releases/notes-v0.0.1-dev.3.md`](docs/releases/notes-v0.0.1-dev.3.md).

> **Gate drift, recorded for this stop.** `dev.2` closed the gate on four entry
> points; keeping Store and Downloads discoverable opened them again on purpose.
> `certificateStudio`, `provisioningProfileManager`, `appStore` and `downloads`
> no longer have a live check anywhere in the Presentation layer: each is still
> declared on `ShellSection.requiredFeature`, but `primaryTabs(where:)` returns
> `true` for the Store and Downloads before consulting it, and Settings → Signing
> offers the Certificates and Profiles rows unconditionally. A Release build at
> `dev.3` therefore exposes four areas the train assigns to `v0.1.0-alpha.1`
> (Certificate Studio), `v0.1.0-alpha.2` (Provisioning Profile Manager) and
> `v0.1.0-alpha.3` (App Store, Download Center). **This stop ships with that
> recorded rather than resolved.** Nothing was re-gated and no train stage was
> moved: either would be a product-surface change made after the build the tag
> points at, and neither was asked for. The two options — re-gate the staged
> *actions* behind each tab, or move these four surfaces into `v0.0.1` and let
> the alphas keep what they actually switch on — are carried to the
> `v0.1.0-alpha.1` cut, where the feature map is written next, and the notes say
> the same in *Gate drift this stop introduces*.

### Fixed

- **A `.p12` could never finish importing, and the reason was a rule the
  platform cannot satisfy.** Registration validated the imported private key
  against one exact Keychain protection class —
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — and against an explicitly
  reported non-extractability attribute. `SecPKCS12Import` takes no attribute
  dictionary, so the items it stores carry the Keychain's default class
  (`kSecAttrAccessibleWhenUnlocked`), and iOS offers no supported way to
  re-protect a private key after creation: `SecItemUpdate` on
  `kSecAttrAccessible` needs the item's data, and a private key never returns
  it. Every identity the platform could legally produce for an import was
  therefore refused, with *The required identity protection is not available* —
  which is what "certificate import does not work" was. The rule now requires
  the property signed identities actually depend on: a private key, never
  synchronizable, unreadable while the device is locked, and not reported as
  exportable; an unreported extractability attribute is the platform's own
  import rather than evidence the key can be exported
  (`SigningKeyProtectionRule`, pinned by `SigningKeyProtectionRuleTests`).
  `ApplePKCS12Importer` additionally *asks* for the device-only class before
  registering and does not assume the answer — the resolver reads the key's
  actual attributes back, so a platform that honours the upgrade gets it and a
  platform that cannot still produces a working, verified identity. The rule
  itself is now a pure type (`SigningKeyProtectionRule.permits`) so it is
  exercised on every run of the test suite, not only in a signed test host with
  `ZYNSIGN_RUN_KEYCHAIN_TESTS=1`; the opt-in Keychain fixture was corrected
  too, because it asked for `kSecAttrIsExtractable` inside
  `kSecPrivateKeyAttrs`, where the platform ignores it, so the key it created
  was exportable — the opposite of the shape the application actually
  registers.
- **An Open In or share-sheet hand-off could be received and never shown.** The
  presentation was requested in the frame ZynSign comes back to the foreground,
  where UIKit drops it without an error, and the state that asked for it stayed
  set — so the Import Hub, the certificate sheet, or the profile sheet never
  opened, and asking again changed nothing. The shell now holds the request and
  honours it the moment the scene is active (`RootView.presentWhenActive`).
- **A package picked inside Files never reached the Import Hub.** `FilesView`
  sent the package to the hub and asked the shell to present it in the same
  frame the document picker was still dismissing — the drop the certificate
  import's password sheet already waited out. The hand-off now waits the same
  settle every post-dismissal presentation in the app uses
  (`PresentationSettle`), one shared beat instead of three invented ones.
- **The tab bar was over the platform's ceiling, and the folded tab crashed.**
  `ShellSection.allTabs` lists six sections; a phone tab bar draws five and
  folds the rest into a system *More* list that *pushes* the overflow. Every tab
  view owns a `NavigationStack` (`RootView.tabContent`), so the folded tab
  nested one stack in another — the fault
  `Scripts/audit_navigation_stack.py` exists to stop, in the one form it cannot
  see, because the push is UIKit's and appears nowhere in this repository. Which
  section folded depended on width and gate state, so one build showed a missing
  Store tab and crashed on Settings. `primaryTabs(where:)` is capped at
  `tabBarItemLimit` (five) and takes the overflow from `tabOverflowOrder`,
  Downloads first, keeping the survivors in declared order; Downloads stays
  openable from Settings → Updates and Store → Download Jobs, and its badge
  follows it there. Locked by
  `ShellSectionTabTests.testTabBarNeverExceedsThePlatformCeiling` and
  `testTheCapDropsOnlyTheLeastWantedSectionAndKeepsTheRestInOrder`. The same
  fault existed in one more place the audit cannot see either: Signing's
  Installation Workspace sheet wrapped the view in a stack *and* asked it to
  embed its own (`embedsNavigationStack` now `false`, as the Settings push
  already does).
- **An environment default could build a second application.** The
  `\.applicationEnvironment` key's default, the two Settings keys' defaults
  (`\.settingsCenter`, `\.appLock`), and `RootView.init`'s default argument
  each called `CompositionRoot.makeApplicationEnvironment()` — the whole graph:
  stores, file caches, background schedulers, and the recovery pass, on the
  main thread, inside whatever view first read the key. A preview, a screen
  built on its own, or any view rendered outside the shell therefore got a
  second library and a second set of preferences that could disagree with the
  shell's, and the construction is main-actor-bound (`MainActor.assumeIsolated`
  around the preferences read), so evaluating it off the main actor traps.
  There is now one shared fallback, `CompositionRoot.fallbackEnvironment`,
  built at most once per process and read by all three keys; `RootView` takes
  its environment as a required argument, so the run path cannot construct a
  composition by omission, and every preview reads the shared instance.
- **A Home shortcut could select a tab that does not exist.** The onboarding
  checklist's *Add a certificate* and *Import a provisioning profile* rows set
  the tab selection to `.certificates` and `.profiles`, neither of which is a
  tab; `TabView` with an unmatched selection draws no selection and an empty
  content area, which reads as a tap that did nothing rather than as a bug.
  `ShellSection.tab(toOpen:)` resolves a slotless section to the surface that
  hosts it, and `RootView` routes every `onOpenSection` through it.
- **A picked `.p12` never opened its password sheet.** The sheet was raised from
  inside the `.fileImporter` completion, in the frame the document picker is
  still dismissing, where UIKit drops a presentation silently — the file was
  read, its bytes held in `pendingData`, and nothing appeared to happen. It now
  waits out the same settle `RootView.presentSigningQueue()` uses for exactly
  this reason. This is the mechanism behind the long-standing *certificate
  import does nothing* report; it still needs a device to be called verified.
- **The Import Hub had one frame, and one chance, to open its picker.**
  `chooseFiles` set a flag that only the hub's own `.task` consumed, so a
  request that landed after the hub appeared was dropped on the floor, and the
  single `Task.yield()` it waited on is not the sheet's transition. Both
  orderings consume the flag now, guarded so the picker opens exactly once.
- **The splash let go while it was still animating.** The shortened launch
  timeline kept the old internals: a `repeatForever` glow pulse, a shimmer
  sweep, a footer on a `0.9 s` delay, and two owners of the exit —
  `ZynSplashView` animated itself out while `ZynSignApp` removed it with a
  spring and a scale/slide. Every stage now finishes inside the 360 ms window
  and the view alone owns the fade, so the handover to `RootView` is one
  motion.
- **A profile picker that failed in silence.** `ProvisioningProfilesModel.handlePickerResult`
  returned early on any non-`.success` result, so a profile the picker could not
  open — not yet downloaded from iCloud, unreadable, refused — disappeared with
  no message at all. Cancellation is now the only quiet path; every other failure
  raises a **Couldn't Open Profile** notice carrying the typed
  `ZynSignError.userMessage` when there is one. Locked by
  `ProvisioningProfilesModelTests.testPickerFailureIsSurfacedButCancellationStaysQuiet`.
- **The tag-time pipeline could overwrite the release's own notes.**
  `Scripts/generate_changelog.py` wrote `docs/releases/notes-v<version>.md`
  unconditionally, and the publish job hands that *path* to
  `gh release --notes-file` after regenerating it — so a hand-written note for
  the stop being released was replaced by a git-log summary in the published
  Release. It now promotes a curated `[Unreleased]` entry verbatim into the
  versioned section (Keep a Changelog semantics, leaving `[Unreleased]` empty)
  and never touches an existing notes file; the commit scrape runs only when
  `[Unreleased]` is empty.

- **A sheet in the Installation Workspace could rebuild itself under the user.**
  `HandoffSheet`'s identity was computed — `var id: String { UUID().uuidString }` —
  so it named a different item on every read. `.sheet(item:)` reads that identity
  on every body evaluation, and the workspace model publishes while a delivery
  runs, so the hand-off sheet was rebuilt — and, on some iOS versions,
  re-presented — while the user was reading it. The identity is now minted once,
  when the hand-off is created: the shape every other presentation item in the
  app already uses. `Scripts/audit_identity_stability.py` refuses a computed
  identity that mints a fresh value, and `01-build.yml` runs it beside the
  navigation-stack audit.
- **Resetting the library could report success for a reset that never ran.**
  `SettingsCenterModel.resetLibrary()` — the one destructive action in the app —
  hid every failure behind `try?`, so a catalog that could not be read produced
  *Removed 0 records and 0 orphaned artifacts*: the silent success
  `performMaintenance` exists to prevent. Enumeration, each removal, and the
  orphan sweep now propagate their typed failures, the count is taken from the
  removals that returned, and the library is read back before the sentence is
  written — a reset that left records behind says so.
- **A setting described the wrong moment.** Settings → Advanced → *Current
  Location* printed the directory derived from the *pending* preference, which
  takes effect at the next launch, under a subtitle that said "right now". The
  row is now *Next Launch Location*, which matches the section's own footer and
  is true whether or not the picker has been changed.
- **An interrupted import could swallow the failure that followed it, and keep
  bytes it never used.** The pause record named only the item, so an attempt that
  ended *after* the system's expiry — cancellation is cooperative, and a copy can
  finish before it is noticed — made a later attempt's failure look like another
  interruption: the item returned to `waiting` and the error it had just
  reported was discarded. The record now names the attempt it interrupted, and is
  consumed whatever it names. The same handler now discards the working copy a
  stopped preparation was still writing: nothing had recorded it, the retry
  stages afresh under a new identifier, and the bytes previously stayed in the
  working directory until the next launch's sweep.
- **Two toolbar menus had no name for VoiceOver, and six labels could shrink
  below the comfort floor.** The icon-only *Add* and *Sort and order* menus in
  Files now carry the `accessibilityLabel` every other icon-only control in the
  app carries, and every `minimumScaleFactor` is at or above the 0.75 the
  accessibility audit treats as comfortable — the audit's review list is empty
  for the first time.
- **A refused identity said only "unsupported", whatever refused it.** When the
  key-protection rule refuses a key, the failure now carries the policy facts the
  Keychain reported — key class, protection class, synchronizable, exportable —
  in the policy's own words (`SigningKeyProtectionRule.describe`, pinned by
  `SigningKeyProtectionRuleTests`). A device that refused an imported key and one
  that reported it exportable used to look identical in the technical log; they
  cannot now.

### Added

- **A searchable, reorderable Settings index.** Settings opens on ten
  categories — Signing, Updates, General, Devices, Servers, Miscellaneous,
  Diagnostics, Reset, About, Socials — each wired to flows that already existed
  rather than to new ones. `.searchable` filters the category list and its rows,
  an empty result gets `ContentUnavailableView.search`, and drag-to-reorder in
  edit mode persists the order under `zynsign.settings.categoryOrder`.
- **Add a repository from where you noticed it was missing.** The Store's empty
  state now distinguishes *No Repositories Yet* from *No Matching Repositories*
  and, in the former, offers the **Add Repository** button inline; the sheet
  takes a **Paste Repository URL** action for a link already on the pasteboard.

### Changed

- **Motion is one policy, and every state change goes through it.** Settings'
  edit-mode toggle named its own curve (`.snappy`) instead of asking `ZMotion`,
  so it was the one transition the app's motion policy — the single place that
  honours Reduce Motion and the animation preference — could not turn off. It
  goes through the shared presets now. The Import Hub animates an item moving
  between sections — prepared, in progress, finished — instead of letting it
  jump; the Library, Certificates, and Profiles screens cross-fade from their
  loading skeleton to content rather than snapping; and the Files listing's
  refresh spinner fades instead of appearing over the list in one frame.
  Progress within a stage is deliberately not animated: a copy reports ten times
  a second, and animating that would be motion without meaning.
- **The Import Hub's own *Choose Files* button raised the picker after an
  invented wait.** Every post-picker presentation waits one settle beat, and
  the hub's picker request waited it even when the hub's sheet had long since
  settled — 400 ms added to the app's primary import action, for a transition
  that was already over. The hub now records when its sheet settles and raises
  the picker on the next frame when it has, keeping the beat only for the case
  it exists for: a request that lands while the sheet is still animating in.
- **The weekly Command Center run no longer changes the repository.** It
  committed regenerated dashboards, applied SwiftFormat, repaired the README,
  synced labels, and ran the stale bot on a schedule — writes to the default
  branch (or a PR) that nobody asked for at the moment they landed. Those five
  jobs now run only for a manual dispatch that names `mode: repair`; the
  scheduled run — and any dispatch that does not ask — analyses, uploads the
  bundle, compares the measurement with the last one, and reports what it found
  in the run summary, including a quality regression it would otherwise have
  opened an issue for.
- **Store and Downloads stay in the tab bar at every release stop.** They are
  primary navigation, and gating them made a development build look like it had
  lost working features. `ShellSection.allTabs` keeps all six destinations, but
  `primaryTabs(where:)` short-circuits the gate for `.appStore` and `.downloads`
  before it reads `requiredFeature`, so that property now governs only the
  sections reached from Settings — Presets and the Installation Workspace. The
  list is what a build *could* show; the bar is the capped result, so Store and
  Downloads are exempt from the gate but not from the five-item ceiling, and
  Downloads is the first to yield a slot. See the drift note above. A saved
  landing preference for either tab remains valid, and
  `testDevelopmentStopKeepsStoreAndDownloadsDiscoverable` pins the policy,
  replacing the test that asserted the opposite.
- **Certificates and Profiles are reached from Settings → Signing.** The old
  Settings → Browse index is gone; *Signing Setup* now holds the `.p12` / `.pfx`
  and `.mobileprovision` import rows and their management views unconditionally,
  which is what makes Certificate Studio and the Profile Manager reachable in a
  development build. Repository, saved-app and download views moved to
  Settings → Updates, source URLs also to Settings → Servers.
- **Import says what it does.** The final action reads *Add 1 App to Library*
  rather than *Import 1 App*, and the hub states that selecting a file only
  previews it — nothing is stored until that last tap.
- **"Source" is now "repository" in the Store.** *Manage Repositories*,
  *Add Repository*, *Validate & Add Repository* and the matching accessibility
  label — the object a user adds is a repository, and the source list is where
  its catalog came from.
- **The release documents describe the gate the code actually runs.**
  `docs/releases/release-train.md` gains a gate map naming which features have a
  live check and which do not, `docs/product/FEATURE_STATUS.md` is re-counted
  against this tree, and the sentences that hardcoded a version —
  `MARKETING_VERSION 0.1.0 · build 2 · .alpha3` in `docs/releases/README.md` and
  `docs/releases/version-strategy.md` — are gone along with a duplicated
  distribution bullet. Numbers come from `python3 Scripts/release_train.py status`
  instead of prose, so a stale line cannot outlive the stop it described; that
  command now prints the six-tab shell as what a development stop shows, rather
  than naming four tabs.
- **The launch splash stopped waiting on a schedule.** The ~1.9 s spring,
  shimmer and haptic sequence is a single fade — 0.36 s, 0.18 s under Reduce
  Motion — with no launch haptics, so the splash cannot delay the first useful
  frame. Splash and prominent-button text uses `Color.primary` instead of a
  hardcoded white, so contrast follows the appearance.
### Added

- **Tweak Library** — import `.dylib`, `.deb`, `.framework`, `.bundle`, and
  `.appex` payloads, organize them into groups, rename, enable, and remove
  them. Imports are SHA-256 de-duplicated and bounded (128 MiB per file, 200
  records). The signing screen stages a validated selection plan and writes
  a manifest beside the signed output recording what the session carried —
  the pipeline still signs exactly the container it is given.
  (`TweakLibraryService` · `FileTweakLibrary` · `TweakLibraryView`)
- **Revocation Center** — one-tap exposure checks per certificate: the
  center reads the OCSP responders and revocation lists a certificate
  publishes (a bounded AIA/CRL scan of the DER) and probes each endpoint
  with a bounded request, reporting `Exposed`, `Partial`, `Shielded`, or
  `No Endpoints` with per-endpoint latency. Results persist per certificate
  fingerprint. The screen states honestly that ZynSign never changes
  network settings; protection happens at the resolver.
  (`CertificateRevocationService` · `URLSessionRevocationProbe`)
- **Release Feeds** — follow the releases a public repository publishes,
  hand a package asset to the Download Center, and track one library app
  per feed. The Updates list compares tracked versions with
  `AppVersionComparison` and never infers an update from dates or from an
  unparseable version. (`GitHubReleaseSourceProvider` · `LibraryUpdateTracker`)
- **App Protection** — per-app Lock (authentication before the detail view
  opens) and a concealed Vault (hidden records stay out of the Library
  until the vault is unlocked for the session). Protection is an interface
  guard over the system's authentication boundary, stated as such — not
  encryption. (`AppProtectionService` · `LockedRecordGate`)
- **Themes** — four shipped themes (ZynSign, Ember, Midnight, Graphite), an
  accent override palette, and a Minimal Interface density mode. The shell
  resolves the theme once and every screen reads it through the
  environment; an unknown stored identifier falls back to the default.
  (`AppThemeCatalog` · `ResolvedAppTheme`)
- **Storage gauge** — the Files screen opens with the volume's used/free
  split, free-space pressure bands (`Comfortable` / `Low` / `Critical`),
  and ZynSign's own footprint. (`StorageGaugeService`)
- **Version History** — Settings → About → Version History: every release
  stop this build knows about, newest first, with what each stop switched
  on. (`VersionHistoryCatalog`)
- **Entitlement merge policy** — pure domain rules for combining an app's
  existing claims with a profile's claims under three modes, with conflict
  and review sets. (`EntitlementMergePolicy`)
- **Bounded version comparator** — `AppVersionComparison`: component-wise
  numeric ordering with explicit incomparability for anything outside the
  shape rules. No date guessing.

### Tests

- Tweak library domain, service, and file-backed persistence round-trips.
- Entitlement merge modes, version comparison, protection visibility
  matrix, storage gauge bands, theme catalog, revocation locator over
  synthetic DER, revocation service over a scripted probe, release feed
  parsing and update tracking, workspace store round-trips.

## [0.0.1-dev.2] - 2026-09-30

**Development 2.** Market `0.0.1` build `3` (`CFBundleShortVersionString 0.0.1`,
`CFBundleVersion 3`), tag `v0.0.1-dev.2`, release train `.dev2`. Notes:
[`docs/releases/notes-v0.0.1-dev.2.md`](docs/releases/notes-v0.0.1-dev.2.md).

Switches on **no** staged feature — like `dev.1`, this stop proves the pipeline
and the core, and a Release build shows Files · Library · Home · Settings.

### Fixed

- **The release gate was not being applied to four shipped entry points.**
  Certificate Studio (declared `alpha.1`), Profiles (`alpha.2`), the Store
  (`alpha.3`) and Downloads (`alpha.3`) were all reachable in every build,
  including a development stop documented as showing the core only. Each
  section now declares the feature that unlocks it (`ShellSection.requiredFeature`)
  and both the tab bar and Settings → Browse honour it. A tab that is gated out
  cannot be remembered as a landing destination either: `RootView.visibleSelection`
  clamps a saved preference to a tab the stop actually shows, so the bar can
  never end up with no selection and a blank content area.
- **Smart Workspace ran on every build.** `CompositionRoot` constructed
  `SmartWorkspaceService` unconditionally, so a Release build wrote
  `SmartWorkspace.json` on every signing session and every application detail
  view from `dev.1` onward — state for a screen nothing presents. The service
  is staged for `rc.2` and is now constructed only at that stop.
- **The README version badge stopped updating at the first pre-release.** The
  pattern could not match a badge that already carried a suffix (`[^-]+` cannot
  cross the `-`, and `(?:--dev)?` covered only `--dev`), so the badge froze the
  moment the train left a bare version — and `update_readme.py --check`, which
  compares the rewritten text, could not see it. Verified against all six
  version forms.

### Added

- **`release_train.py rewind STAGE`** — move the declared stop back to an
  earlier one. `promote` refuses to move backwards because a released stop must
  never be re-released and no user may lose a feature; this command keeps that
  guarantee by refusing any target at or behind the highest stop that already
  carries a tag, and fails closed when it cannot read the tags. It exists
  because the declared stop had run ahead of what had actually shipped: the
  branch said `alpha.3` while only `dev.1` was ever released, so no tag could be
  cut for the stop that was really next.
- **`Scripts/ci/local_lint.py`** — a local pre-flight for the exact rules the
  two quality gates enforce, so blocking findings are visible without a macOS
  runner.


## [0.0.1-dev.1] - 2026-09-29

**First build — development stop 1.** Market `0.0.1` build `1`
(`CFBundleShortVersionString 0.0.1`, `CFBundleVersion 1`), tag `v0.0.1-dev.1`,
release train `.dev1`. Notes:
[`docs/releases/notes-v0.0.1-dev.1.md`](docs/releases/notes-v0.0.1-dev.1.md).

ZynSign is an on-device iOS signing app: import an application package, inspect
it, sign it with your own certificate and profile, and hand off the result —
inside the app sandbox, with no desktop helper, no remote service, and no
analytics.

This build is a **development stop**. It switches on no staged feature: what it
exposes is the core — Files, Import (`ipa`/`tipa`), Library, Bundle Explorer,
Home, and Settings. Everything else is already compiled into the binary and
stays hidden until the stop that introduces it
([`docs/releases/release-train.md`](docs/releases/release-train.md)). Debug
builds expose every feature, so development and UI work are never blocked, and
`-ZynSignReleaseStage <stage>` previews any later stop.

**Version series.** ZynSign's numbers start at `0.0.1` here: `0.0.1-dev.N` are
its development stops, `0.0.1` is the first build, and the progression continues
through the alphas (`0.1.0-alpha.N`), betas (`0.9.0-beta.N`), release candidates
(`1.0.0-rc.N`) and `1.0.0`
([`docs/releases/version-strategy.md`](docs/releases/version-strategy.md)).

### Added

- **The app** — the six-surface shell (`Files · Library · Home · App Store ·
  Downloads · Settings`), `ipa`/`tipa` import (bounded, security-scoped,
  SHA-256), a durable library that survives relaunch, duplicate detection, a
  read-only bundle explorer, and a Files browser over ZynSign's own container.
- **Certificate Studio** — `.p12`/`.pfx` import (≤ 10 MiB) into the Keychain via
  `SecPKCS12Import`, stored `WhenUnlockedThisDeviceOnly`, non-extractable,
  duplicate SHA-256 rejected; detail view with subject / issuer / serial /
  SHA-256 / validity and a **public-metadata JSON export** only.
- **Smart Sign** — the nine-stage signing pipeline behind a single validated
  call: isolated working copy, inner-first nested signing, independent re-read
  verification of the signed copy, packaging, and a container check before
  anything reaches `Documents/Signed`. A refused run names the stage, the
  reason, and the recovery facts, and never leaves a half-signed artifact where
  it could look complete.
- **Compatibility Lab** — the in-app validation dashboard (Debug and internal
  builds): it builds synthetic packages, exercises the pipeline, and reports
  what it found, with every row stating what was verified and what next.
- **Honest limitations as a shipped document** —
  [`docs/product/WHAT_DOES_NOT_EXIST.md`](docs/product/WHAT_DOES_NOT_EXIST.md)
  records what is wired and the three capabilities that are claimed *never*
  (in-app installation, Pairing/JIT/Mux, off-device analytics).
- **The engineering system** — five workflows (🔨 Build, 🛡 Quality,
  🚀 Release, ⚙ Command Center, Release Drafter) enforcing hygiene, build and
  unit tests, lint and format, architecture boundaries, complexity, dependency
  and secret scans, documentation checks, and external validation. One tag
  publishes a release: `Scripts/ci/release_assets.sh` derives the whole
  version-stamped asset set (`ZynSign-v{tag}-unsigned.ipa`,
  `-SHA256.txt`, `BuildPassport-v{tag}.json`, `MANIFEST.md`,
  `ReleaseNotes.md`) from the tag, and `dry_run: true` rehearses it without
  publishing. Every log speaks one language (Crystal Flow,
  `Scripts/ci/crystal.sh`). See
  [`docs/releases/release-automation.md`](docs/releases/release-automation.md).
- **Release train** — `ZynSign/Application/ReleaseTrain.swift` is the single
  source of truth for which features each release switches on, kept in step with
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` by
  `python3 Scripts/release_train.py`.

### Known limitations

- **In-app installation does not exist.** No supported mechanism exists for an
  iOS/iPadOS app to install an arbitrary IPA; ZynSign builds the OTA manifest,
  the `itms-services://` link and a QR for a host you control, and says plainly
  that it never installs.
- **Pairing / JIT / Mux is never claimed** — it would require private
  entitlements. See `docs/architecture/pairing-jit-mux-feasibility.md`.
- **No off-device measurement.** There is no analytics SDK, no endpoint and no
  identifier; the local activity journal is on-device and cannot transmit.
- **Not signed for the App Store.** Distribution is sideload or TestFlight.
- **No device evidence yet.** The private matrix in
  `docs/releases/private-testing.md` has not been run for this stop, and no
  result in the notes is claimed on its behalf.

### Tests

Unit, host-vector and audit suites run in CI; the
`Build and test (Xcode)` job is the judge of their results, and this entry
claims nothing about them before it has run. The release notes for this stop
record which host audits were executed and which were not.
