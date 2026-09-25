# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `docs/releases/version-strategy.md` for the pre-1.0 progression and
`docs/releases/private-testing.md` for the private → public gate.

> **Distribution:** Every `0.1.0` build is sideload / TestFlight only — no
> App Store submission and no install claim (see `docs/architecture/installation-compatibility.md`).

## [Unreleased]

### Added — 0.1.0-alpha.1 · Step 5: Provisioning Profile Manager

- **Profile Library rebuilt as a manager** — the Profiles tab now lists
  every imported profile as a row or card carrying name, team name, team
  ID, distribution type, expiration status with remaining days, device
  count, import date, and a compatibility indicator, with a List/Grid
  toggle, instant search (name, team, UUID, App ID, bundle patterns),
  sort (expiration / name / recently imported / type), and filters by
  type and expiration state. Cards mark the profile pinned by
  "Use for Signing"; a friendly illustration, a plain-words explanation,
  and the Import Profile button open the empty state.
- **Richer profile summaries** — summaries now record the profile UUID,
  team name, creation date, distribution type, device count, full App ID
  with its explicit bundle identifier, and the embedded certificates'
  SHA-256 fingerprints. Every new field is optional, so catalogs written
  before this step keep decoding under schema 1; Refresh Validation
  backfills them from the stored file.
- **Bundle-pattern derivation fixed** — the importer now derives
  `covers(bundleIdentifier:)` patterns from the parsed exact-or-wildcard
  App-ID component (exact → the bundle ID, wildcard → `prefix.*`,
  team-wide → `*`) instead of a team-prefixed guess that never matched a
  plain bundle identifier. Legacy catalog entries are repaired by
  Refresh Validation, which re-reads the stored `.mobileprovision`,
  re-parses it, and updates the summary while keeping its identity and
  import date.
- **Profile import summary** — a successful import presents a summary
  sheet (team, type, App ID, wildcard/explicit, devices, dates, UUID,
  certificate count, compatibility quick look) before the library
  refreshes; corrupted or unsupported files are refused with their typed
  message and an "Unsupported Profile" title where the format is out of
  scope, and oversized files are refused before they are read.
- **Profile Details, General / Application / Distribution** — the detail
  screen shows name, UUID, team name, team ID, creation and expiration
  dates; App ID, bundle identifier, wildcard-vs-explicit status, and the
  covered patterns; distribution type, device count, certificates, and
  debug permission — inspection only, including the App Store case.
- **Smart Compatibility Engine** — five pre-sign checks (bundle ID match,
  team ID match, certificate available, profile expired, profile type
  supported) each render ✅ / ⚠️ / ❌ / unsupported with an actionable
  message, and roll up into a Compatibility Summary (Compatible / Needs
  Attention / Not Compatible / Unsupported). The engine is pure domain
  logic; the application layer assembles the context from `IdentityStore`.
- **Expiration intelligence** — Healthy / Expiring Soon (≤ 30 days) /
  Expired with remaining days and semantic badges everywhere the library
  shows a profile.
- **Profile Matching** — opening an app's detail screen ranks the library
  for that app (exact over wildcard, certificate on device, team match,
  supported type, longer validity) and suggests the best profile with its
  reasons; the pinned "Use for Signing" profile is offered first when it
  ranks, and "Change…" records a per-app manual override — including
  honest display of an override that no longer suits the app — with
  "Profile not suitable for this app" shown when nothing qualifies.
- **Diagnostics Panel** — profile detail lists one message per finding
  with Success / Warning / Error / Unsupported severity badges: bundle ID
  mismatch, missing certificate, expired profile, unsupported
  distribution type, unrecorded certificates (Refresh Validation), and
  more.
- **Quick actions** — View Details, Use for Signing, Copy Team ID, Copy
  Bundle ID, Refresh Validation, and Remove on every profile, from both
  context menus and swipe actions, plus the same actions inside the
  detail screen.

### Added — 0.1.0-alpha.1 · Step 4: Certificate Manager

- **Certificate Library** — the Certificates tab is now a real library of
  signing identities. Each identity shows as a professional card (list row
  or grid card, with a persisted list/grid toggle): the certificate name
  (or the user's local display label), team name, Team ID, certificate
  type (Development / Distribution / Other), expiration status, import
  date, and key availability. The list is searchable while typing by name,
  team, issuer, or fingerprint, sortable by name, team, expiration, or
  import date, and filterable by expiration state, certificate type, and
  team — with an explicit "nothing matches" state and one-tap filter
  clearing.
- **Expiration intelligence** — every identity is classified at read time
  against an explicit instant: Healthy, Expiring Soon (within a 30-day
  threshold, inclusive of the boundary), Expired, or Not Yet Valid. The
  classification is pure domain logic (`CertificateExpirationAssessment`),
  carries the whole-day remaining count (negative when expired), and is the
  source of the coloured indicators on cards, rows, and the details screen.
- **Import signing identity** — the `.p12` / `.pfx` import flow is
  unchanged in its security model: select the file, enter the password,
  the container is validated, and the identity is registered through the
  secure store. The password travels once to the importer and is never
  stored, logged, or shown again; a failed import keeps the password sheet
  open with the typed reason, and a successful one closes into a success
  summary naming the imported identity, its team, type, expiration, and
  key state. The import date is recorded in the identity's local notes.
- **Certificate details** — a dedicated details page per identity, in the
  order a developer reads it: Identity (common name, organization, team
  name, Team ID, display label), Certificate (issuer, serial, algorithm
  with key size and curve, signature algorithm, SHA-256 fingerprint,
  self-signed, import date), Validity (created, expires, remaining days,
  status), and Key Status (availability, association, capability, usable
  for signing). The screen reads the identity live from the model by
  fingerprint, so a change made anywhere is reflected without the screen
  going stale — and a removal takes it to an honest "no longer available"
  state.
- **Team and type extraction** — the certificate's own subject declares its
  team: the ten-character Team ID from the organizational unit (falling
  back to a trailing `(TEAMID)` group in the common name) and the team name
  from the organization attribute. A bare common name declares no team;
  nothing is invented. The certificate type is read from the common-name
  prefix Apple's tooling uses ("Apple Development: …", "Apple
  Distribution: …", and the legacy names); an unrecognised name is "Other",
  not an error.
- **Default identity** — the user marks one identity as the default for
  future signing; the library names it in its own header, badges it on
  the card and the details page, and the mark is persisted locally by
  fingerprint. Removing a default's identity clears the mark, and a mark
  that names no registered identity is cleared on load rather than kept as
  a ghost.
- **Quick actions everywhere** — view details, set or clear the default,
  rename the display label (local only — the certificate is never
  changed), copy the Team ID, and remove the registration. They are
  available from swipe actions, long-press context menus, and the details
  page, with toasts confirming each outcome.
- **Local notes, stored safely** — display labels, import dates, and the
  default mark live in a new local annotation store
  (`FileIdentityAnnotationsStore`), keyed by the certificate's public
  SHA-256 fingerprint and holding nothing but those display values: no
  passwords, no key references, no keychain accounts. The catalog is
  versioned, written atomically, and fails closed on damage — an
  overlong label, an invalid fingerprint key, or an unsupported schema is
  reported as unreadable and left in place, never reset. Labels are bounded
  (120 characters) at the boundary; a longer label is refused, not
  truncated.
- **Removal joins the port** — `IdentityStore` now answers one more
  question: how to forget a registration. Removing a registration never
  deletes the borrowed key, which remains owned by its provisioning
  component; the Certificates screen no longer needs to know which store
  implementation it holds.
- **Empty state** — with no identities the screen shows a short,
  friendly, non-technical invitation and a single Import Certificate
  button, instead of a technical explanation.
- **UX** — smooth list/grid and filter/sort transitions, search while
  typing, swipe and context-menu actions, Dynamic Type through semantic
  fonts, VoiceOver labels that carry the state in words (colour only
  reinforces), dark mode throughout, and an adaptive grid that gives the
  iPad the same content in a wider layout.

### Added — 0.1.0-alpha.1 · Step 2: Production-Grade IPA Import

- **Import queue** — `PackageImportQueue` accepts packages from every entry
  point and runs them one at a time in the order the user asked, because
  staging, adoption, and the duplicate question all want the machine to
  itself. Each job carries its own state (waiting / running / waiting for a
  decision / settled), its own progress, and its own way out: cancel the one
  that is running, retry the one that failed or was cancelled, remove the
  ones that are finished. Progress reports are applied monotonically, so a
  late report can never make an import appear to undo work.
- **One import experience** — `ImportQueueView` is the single import area:
  the file picker, the queue, per-job progress, the duplicate question, and
  a batch summary that counts what happened (added / already held / refused /
  failed / cancelled, and the sizes measured) without claiming anything about
  a package. The shell owns it (`RootView`), and Home, the Library, Files, a
  share-sheet hand-off, and a drag-and-drop all open the same one through
  `EnvironmentValues.importPresentation`.
- **Share Sheet and open-in import** — a package shared or opened into
  ZynSign from another application is routed to the queue and continues
  straight into the import flow. ZynSign is also registered as a viewer for
  provisioning profiles and identities; those documents keep their own flows
  and are never pushed at the package queue.
- **Drag and drop** — dropping one or more `.ipa` files onto the import area
  queues them; pull-to-refresh on the same list opens the picker.
- **Duplicate detection with a three-way decision** — the comparison runs
  against the *staged copy* before anything is committed and reports the
  evidence (bundle identifier, declared version, build, content fingerprint)
  rather than a verdict. `Keep Both`, `Replace Existing`, and `Cancel Import`
  each do exactly what they say: keeping both stores a further entry and
  leaves every existing record alone; replacing stores the new entry *first*
  and only then removes the entries it matched, so a failure leaves the
  library holding more than asked rather than less — and reports the entries
  it could not remove; cancelling stores nothing and discards the staged
  copy. Version and build differences are information, not collisions, so the
  question is asked only where there is something to decide.
- **Pre-import validation before anything is copied** — the selected document
  is described first (name, size, kind, and whether its leading bytes are an
  archive signature) and refused there and then if it is empty, a directory,
  larger than the 4 GiB ceiling, or does not begin like a package archive;
  every refusal is a typed, user-readable reason. The archive and metadata
  examinations still decide validity, about the copied bytes.
- **The selected file is only ever read** — staging copies in bounded chunks
  inside a file-coordination access with a direct-read fallback, acquires and
  releases the security scope per operation, and never opens the source for
  writing, moves it, renames it, or deletes it. A failed or cancelled staging
  removes the partial copy and nothing else.
- **Failure vocabulary** — `ImportFailure` composes title, message, and
  recovery for every way an import can end, with retry offered only where a
  second attempt can plausibly end differently (storage and internal
  failures, cancellations) and never for a refusal or a recognised
  duplicate. `ImportSettlement` and `ImportSummary` carry those outcomes to
  the interface, and `ImportQueueRendering` is the single place they become
  sentences.
- `PackageImportQueueTests` (ordering, progress, cancelling, retrying,
  duplicate answers, removal, summary), `DuplicateImportTests` (the real
  pipeline: recognition, keeping both, replacing, kept neighbours, failed
  removal), `ImportQueueRenderingTests` (the wording), `ImportPreflightTests`
  (every acceptance and refusal, including the ones preflight must not
  make), and new `SecurityScopedArtifactIntakeTests` coverage for describing
  a document and for progress reporting.

### Changed

- The single-package import path now runs through the queue:
  `IPAPackageImport` gained a pre-import validation stage and the duplicate
  decision seam, `ApplicationLibrary` gained `duplicateReport(for:)` and an
  admission policy that can hold two copies of the same bytes on purpose, and
  `ApplicationLibraryModel` observes the shared queue instead of driving its
  own import model. `PackageImportModel` and `PackageImportView` are removed;
  the Library, Home, and Files screens route their import actions through the
  shell's import area and no longer present pickers of their own.
- Import analytics are recorded once per settled job by the shell
  (`import.accepted` / `import.rejected`), whatever entry point started it.

### Added — 0.1.0-alpha.1 · Step 1: Home Dashboard & App Library

- **Home Dashboard** — the screen users land on: a welcome header with a
  time-of-day greeting, a Quick Actions row (**Import IPA · Certificates ·
  Profiles**), **Recently Imported** (the newest three applications, each
  opening its detail), and **Library statistics** (Apps / Certificates /
  Profiles) with tiles that open the tab that manages each count. Every
  number is read from the same use cases the tabs read — nothing is
  decorative, and a count that cannot be read shows "—", never a
  fabricated zero.
- **First-launch onboarding** — an empty-state card on Home walks through
  importing an application, adding a certificate, and importing a
  provisioning profile. Each step is marked complete only when the
  corresponding store actually holds something; it dismisses for good and
  completes itself once all three are true.
- **App Library power tools** — grid/list layout toggle (remembered across
  launches), instant search across declared name, bundle identifier, and
  source file name, sorting by **Recently Imported / Name / Version**
  (versions sort the way people read them: 10.0 above 2.0), swipe actions
  (**Favorite**, **Details**, **Delete**) with context-menu equivalents on
  grid cards, and **multi-selection mode** (Select/Done, Select All /
  Deselect All, confirmed bulk delete).
- **App cards and rows** — each shows the application's **icon** (extracted
  read-only from the package through `AppIconExtraction`, bounded and
  cached, with an honest monogram-and-palette fallback derived from the
  bundle identifier when the package carries no readable icon), the app
  name, bundle ID, **version + build**, import date, a **signing status
  badge** (read from the on-device signing journal — "Signed" only where
  successful output is recorded; a package whose bytes drifted from its
  record says so), and a **favorite indicator**.
- **Profiles tab** — the provisioning-profile library as a first-class tab:
  import `.mobileprovision` (validated through the same inspection use case
  the signing pipeline composes), a list with team, expiry countdown, and
  semantic badges (valid / expiring soon / expired), a detail screen with
  bundle-identifier patterns and entitlement keys, and delete with
  confirmation. Composition composes `ProvisioningProfileImporter` for the
  first time and stores profile files beside the profile catalog.
- **Navigation foundation** — the shell is five tabs: **Home, Library,
  Certificates, Profiles, Settings**. Files, App Store, and Downloads
  remain complete, reachable areas — linked from Settings → Browse — so
  the bottom navigation is a stable foundation for the milestones that
  follow.
- `AppIconExtractionTests`, favourite tests in `ApplicationLibraryTests`,
  search/sort/favourite/signing-state/bulk-removal tests in
  `ApplicationLibraryModelTests`, and catalog schema-2 tests including the
  schema 1 → 2 conversion.

### Changed

- **Library catalog schema version 2** — records carry the user's favourite
  mark. A schema 1 catalog converts at the read boundary (every record
  reads not-favourite) and is rewritten in the current schema at its next
  mutation; version 0 and anything newer than this build are still refused,
  and a read never rewrites the file.
- `ApplicationRecord` gains `isFavorite` (display-only preference; import
  time and identity are untouched by the change) and
  `ApplicationLibrary.setFavorite(_:recordWithID:)`, a no-op when the mark
  already matches.
- Settings reorganised for the new shell: Certificates has its tab, Signing
  Options stays under Signing, and Browse links to Files / App Store /
  Downloads under the existing release-train gates.

### Added

- **Release train** — `ZynSign/Application/ReleaseTrain.swift` (`ReleaseFeature`,
  `ReleaseStage`, `ReleaseTrain.current`, `ReleaseGate`) decides which finished features a
  build exposes. Release builds show exactly `ReleaseTrain.current`. Debug builds show
  everything, or one release's view with the `-ZynSignReleaseStage <stage>` launch argument.
  Gated: App Store / Downloads tabs, Certificates, Sign, Signing Options, Installation,
  Deliver…, Mission Control, and the Activity Journal (including recording).
  Settings → Diagnostics shows the active release.
- `Scripts/release_train.py` — `status` / `check [--tag]` / `promote [stage]`. It keeps
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in step with `ReleaseTrain.current`.
- `ReleaseTrainTests` — order, accumulation, single introduction, prerequisites, gate, preview override.
- `docs/releases/release-train.md` — the plan and the per-release procedure.

### Changed

- CI hygiene runs `release_train.py check`. `release.yml` refuses a tag that isn't
  `ReleaseTrain.current`, publishes alpha / beta / rc tags as pre-releases, and pushes the
  generated changelog to the default branch instead of a stale session branch.

### Fixed

- Home → **Library** and **Files** quick actions now switch tabs (they did nothing).
- Home **Signed** / **Sources** stats show real counts (`Documents/Signed/*.ipa`,
  saved sources) instead of a permanent “—”.
- Mission Control no longer force-unwraps the sources file URL (possible crash).
- Library **Signed** segment shows the real signed-IPA count and where to find them.
  The old copy said signing “was not yet composed”.
- Pairing screen and comments no longer mention the retired “0.1.0-dev → 0.2.0” versions.
- Removed an unused `onInfo` parameter from the Files row.
- Docs point to `main` instead of a stale session branch. The TestFlight build number is `4`.
- Private Test Build runs the release-train check and warns that Debug shows every feature.

### Staged (built, switched on by a later release)

| Release | Switches on |
|---|---|
| `v0.1.0-alpha.1` | Certificate Studio |
| `v0.1.0-alpha.2` | Smart Sign (9 stages, DER, Live Activity, Signing Options, Installation screen) |
| `v0.1.0-alpha.3` | App Store + Repository Health, Background Downloads |
| `v0.9.0-beta.1` | Mission Control, Installation Delivery Hand-off, Local Activity Journal |

## [0.1.0] - 2026-09-25

First public development build — **Horizon** — tagged from `main`.
Market `0.1.0` build `4` (`CFBundleShortVersionString 0.1.0`, `CFBundleVersion 4`),
tag `v0.1.0`. The same binary is tested privately (TestFlight internal / ad-hoc IPA)
and then published — no rebuild between private and public.

**Release train.** The whole app is built into this binary, but `0.1.0` *shows*
only the core: **Files, Import (`ipa`/`tipa`), Library, Bundle Explorer, Home, and
Settings**. Every other feature below is marked with the release that switches it
on (`ReleaseTrain.swift`, see `docs/releases/release-train.md`). Hidden features
can't be reached from the interface and record nothing.

The codebase completes `docs/product/WHAT_DOES_NOT_EXIST.md`: **9 wired, 3 never** —
in-app installation, Pairing/JIT/Mux, and off-device analytics stay claimed-never,
while the installation delivery hand-off and the local activity journal are wired
(visible from `v0.9.0-beta.1`).

### Added

- **Import, Library, Files, Bundle Explorer** *(visible in `v0.1.0`)* — import `ipa`/`tipa`
  from Files or Home (security-scoped, bounded, SHA-256), durable library that survives
  relaunch, duplicate detection, missing-artifact banner, read-only bundle explorer,
  and a Files browser over ZynSign's own container.

- **Certificate Studio + Export** *(built · visible from `v0.1.0-alpha.1`)* — Import `.p12`/`.pfx` (≤ 10 MiB) via `SecPKCS12Import`,
  store in `SecureIdentityStore` (`WhenUnlockedThisDeviceOnly`, non-extractable, duplicate
  SHA-256 rejected). `Settings → Certificates` shows subject / issuer / serial / SHA-256 /
  validity / key info with `ZStatusBadge` and exports *public* JSON only
  (`CertificateExportService` → `tmp/ZynSign-Export/*.json` via `UIActivityViewController`).
  Private key never leaves the Keychain.

- **Smart Sign (9 stages)** *(built · visible from `v0.1.0-alpha.2`)* — `Library → Sign` / `Detail → Sign` runs
  `integrity → profile → discovery → extraction → nestedSigning → resourceSealing → mainExecutable → packaging → verification`
  with `ZProgressRing` + `ZSigningStatusMachine`. Entitlements are derived from the
  `.mobileprovision` (CMS → plist → `CodeSigningEntitlements`, unknown keys preserved,
  8-key preview) with fallback to empty only when derivation fails. `tipa` accepted as alias for `ipa`.

- **DER entitlements (iOS 15+)** *(built · visible from `v0.1.0-alpha.2`)* — Toggle `0x20200` (slot 5) / `0x20400` (slot 5+7) in
  `SigningView`. `DEREntitlementsSerializer` produces deterministic `DER SET` (`0xFADE7172`)
  and `CodeDirectoryVersion.v20400` (52-byte header, slot 7 gated). Pipeline wired via
  `SignApplicationOptions.emitDEREntitlements` (default `false`).

- **Live Activities** *(built · visible from `v0.1.0-alpha.2`)* — `LiveActivityService` (`ActivityKit` on iOS 16.1+, in-app `ZStatusBadge` fallback)
  mirrors `ZynSignLiveActivityState` (stage / progress / detail) during signing
  (`start → update 0.2/0.9 → end`) in `SigningView`.

- **Repository Health** *(built · visible from `v0.1.0-alpha.3`)* — `App Store` sources show `Fast < 800 ms` / `Slow < 3 s` / `Offline`
  (`RepositoryHealthProbe` 3 s, `reloadIgnoringLocalCacheData`, HTTP 2xx + JSON validation).
  Row displays `ZStatusBadge` + latency and `Check Health` on demand; `refresh()` maps latency to health.

- **Background Downloads** *(built · visible from `v0.1.0-alpha.3`)* — `Downloads` uses `BackgroundURLSession` (`com.zynsign.downloads`,
  60 s request / 600 s resource, `waitsForConnectivity`, `sessionSendsLaunchEvents`) with
  resume data, retry × 3, SHA-256 verification, `Pause` / `Resume` / `Cancel`, and progress.
  Survives backgrounding (foreground on Simulator).

- **Mission Control** *(built · visible from `v0.9.0-beta.1`)* — `Home → Refresh Everything` (`MissionControlService`) runs
  `refresh repositories → library re-read → cache cleanup` (`tmp` 24 h + `Downloads` 500 MiB / 7 d)
  with report (`Completed` / `Unavailable` + counts + duration ms). Re-sign is policy-checked, never auto-triggered.

- **Honest capabilities (explicit)** — `InstallationCapability` (`deliveryMechanismAvailable == false`,
  `Settings → Installation` `Unavailable` with the hand-off described), `PairingCapability`
  (`allUnavailable` + feasibility notes, `Settings → Pairing` `Never`), `AnalyticsPolicy`
  (`isEnabled == false`, `0 events sent`, 6 guarantees incl. `localJournalOnly`).
  See `docs/product/WHAT_DOES_NOT_EXIST.md` for code references.

- **Installation delivery hand-off** *(built · visible from `v0.9.0-beta.1`)* — `Sign → Deliver…` opens `InstallationDeliveryView`
  (`Application/InstallationDelivery.swift`): enter the HTTPS address where you will host the
  signed IPA and ZynSign builds Apple's `itms-services` `manifest.plist`, a percent-encoded
  install link, an on-device QR code (Core Image `CIQRCodeGenerator`,
  `Platform/DeliveryQRCodeRenderer.swift`), and step guides for the three operator channels —
  OTA hosting, MDM, and host tooling. HTTPS-only by design (`file://`/`http://` refused with a
  typed `InstallationDeliveryError`). ZynSign never uploads, hosts, probes a server, or learns
  an installation outcome; `deliveryMechanismAvailable` stays `false` on every path.

- **Local activity journal (on-device analytics)** *(built · visible from `v0.9.0-beta.1`)* — `LocalAnalyticsEvent` (category + fixed
  slug + outcome + time — no bundle identifiers, paths, or device/user identifiers) recorded
  by `FileLocalAnalyticsJournal` (JSONL in the app container, capacity 500, atomic writes,
  damaged lines skipped) behind the `LocalAnalyticsRecording` port
  (`Application/LocalAnalyticsJournal.swift`), composed in `CompositionRoot` and gated by the
  `AnalyticsPolicy.journalDefaultsKey` preference. `Settings → Analytics` shows the toggle,
  live counts, recent activity, one-tap Clear, and Export. Wired call sites: import, sign,
  certificate import, download outcomes, delivery manifest generation. Events never leave
  the device.

- **Pairing/JIT/Mux feasibility record** — `docs/architecture/pairing-jit-mux-feasibility.md`
  records the rejected-never decision: the private surface each capability needs
  (MobileDevice/lockdown entitlements, `get-task-allow` + paired debugserver, the `usbmuxd`
  socket, OpenSSL linkage), why it is out of reach for a sandboxed app, what ZynSign does
  instead, and the triggers that would reopen it. `PairingCapability` carries per-capability
  `feasibilityNote` + `documentationAnchor`, rendered by Settings → Pairing / JIT / Mux.

- **Capability tests** — `PairingCapabilityTests`, `AnalyticsPolicyTests`,
  `LocalAnalyticsJournalTests`, `InstallationDeliveryTests` pin every `supported == false`,
  the exact limitation sets, the journal contract (recency, counts, capacity pruning,
  corruption tolerance, clearing, persistence, redaction), and the manifest shape /
  HTTPS enforcement / link encoding.

- **Design System** — `ZCard`, `ZStatusBadge`, `ZSkeleton`, `ZProgressRing`, `ZToast`, `ZBottomSheet` +
  `DesignTokens` (ZDL v1.0), liquid glass, spring + haptics, Dark Mode. Four-layer
  `Presentation → Application → Domain ← Platform` via `CompositionRoot`.

- **Release automation** — `Scripts/generate_changelog.py` + `.github/workflows/release.yml`
  (auto changelog on `v*` tag) and `Scripts/update_readme.py` + `.github/workflows/update-readme.yml`
  (auto README badge sync from `MARKETING_VERSION` and `WHAT_DOES_NOT_EXIST`).

### Changed

- `MARKETING_VERSION` is `0.1.0` (numeric, App Store expectation); the `-dev` suffix
  lives only in history tags. `CURRENT_PROJECT_VERSION` is `4` for private + public (next build `5`).
- `AnalyticsPolicy` distinguishes off-device measurement (`isEnabled == false`, `eventCount == 0`,
  `endpoint == nil` — unchanged) from the local journal: new `journalDefaultsKey`, `journalCapacity`,
  `isJournalEnabled`, and a sixth guarantee `localJournalOnly`; `noTelemetry` is now
  `noTelemetryTransmission` ("No telemetry event ever leaves the device.").
- Settings → Installation / Pairing / Analytics copy updated for the hand-off, the feasibility
  notes, and the journal; README + `WHAT_DOES_NOT_EXIST.md` counts derived as `9 wired · 3 never`.
- `CodeDirectoryVersion` adds `v20400` (52 B, `supportsDEREntitlements`), `CodeDirectoryError` adds `derEntitlements`.
- `SignApplicationOptions.emitDEREntitlements` (default `false`) wires `v20200` / `v20400`.
- `IPAFileFormat` / `ImportablePackage` accept `tipa` as alias for `ipa`.

### Fixed

- `SigningView` diagnostic + `entitlementsSection` corruption (escaped newlines) — rebuilt clean.
- `InstallationEvidence` typo `.notValidated` → `.indeterminate` in `SettingsView`.

### Security

- No `kSecReturnData`, no key export, no `SecKeyCopyExternalRepresentation`; `CertificateExportService`
  exports public JSON only, `ShareSheet` is `fileprivate`, diagnostics redacted. Pairing / Analytics
  declare no private entitlements and no telemetry. The local activity journal stores category /
  slug / outcome / time on-device only — no identifiers, no transmission; the private matrix
  verifies with a proxy. See `SECURITY.md`.

### Notes

- **Sideload only** — not App Store, not install-claiming. Deliver `Documents/Signed` via MDM / OTA + confirmation.
- **Private → public gate** — this tag (`v0.1.0`) is the privately tested commit (`docs/releases/private-testing.md`
  matrix on iOS 17 + iOS 18, two devices + simulator).
- **Built on** `main` (Horizon `58e604c` + installation delivery hand-off, local
  activity journal, pairing/JIT/mux feasibility record; market `0.1.0` build `4`).
  History tags `v0.1.0-dev` / `v0.1.1-dev` / `v0.2.0-dev` at `58e604c`.
- **External validation** (ZS-031, runs `36010725148` / `36011553668`): `codesign` accepts single-image,
  rejects pipeline bundle (`files2`-only seal); format fails iOS 15+ `0x20200`/`DER` — addressed by `0x20400` toggle,
  but no iOS trust or installability is claimed (`docs/architecture/external-validation.md`).

---

Full history since inception is preserved in git (`git log --oneline`) and in previous
changelog drafts. This file starts its professional history at `0.1.0`.

[Unreleased]: https://github.com/raynmahbub/ZynSign/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/raynmahbub/ZynSign/releases/tag/v0.1.0
