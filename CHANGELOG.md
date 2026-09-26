# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `docs/releases/version-strategy.md` for the pre-1.0 progression and
`docs/releases/private-testing.md` for the private → public gate.

> **Distribution:** Every `0.1.0` build is sideload / TestFlight only — no
> App Store submission and no install claim (see `docs/architecture/installation-compatibility.md`).

## [Unreleased]

### Added — 0.1.0-alpha.2 · Step 13: Smart Import Hub

- **One Import Hub for every entry point** — `ImportHub` (Application) replaces
  the one-at-a-time import queue. The Files picker (multi-select), the share
  sheet, Open In, drag and drop, the Files browser, and the ⌘I / ⌘O
  shortcuts all hand files to `ImportHub.receive(_:origin:)`, and the shell
  presents the one `ImportHubView`. Share-sheet copies (`Documents/Inbox`)
  and in-place Open In requests are told apart for labelling only
  (`ImportOrigin.openIn`); arrivals from either within two seconds of each
  other form one batch.
- **Multi-import queue** — every file is its own item with its own stage
  (Waiting, Preparing, Validating, Analyzing, Importing, Complete, Failed —
  `ImportQueueStage`), progress, remaining-work line
  (`ImportRemainingEstimate`: steps left, bytes left, and a time estimate
  only once a copy has run for a second and passed 5 %), icon once analyzed,
  Cancel, and Retry. Up to two items prepare at once; each fails, retries,
  or is cancelled independently. Confirmed packages are stored one at a
  time so the library's admission is never raced.
- **Drag and drop on iPad** — `importDropTarget()` makes Home, the Library,
  the Import quick action and empty-state button, the hub itself, and the
  hub's dedicated `ImportDropZone` accept dropped files. Targets highlight
  and preview how many files would be imported; a drop opens the hub.
  Dropped files are copied into a ZynSign-owned inbox while the drop is
  handled (`DropInboxFileReceiver`), released once imported, and swept at
  launch; items that cannot be received as files are still listed.
- **ZIP archives, opened safely** — `.zip` files are accepted as containers.
  `PackageContainerClassification` decides from the entry table alone,
  before anything is extracted: a `Payload/` layout is a package; an archive
  of `.ipa` / `.tipa` files offers them (one package → **Extract App**,
  several → a selection sheet); an archive with none, an Xcode archive, a
  bare `.app`, or archives-inside-archives is refused with its own
  explanation. Any unsafe entry name, duplicated entry, case-colliding
  package name, or package-named link refuses the whole archive. macOS
  resource forks are never offered. `ZipEntryStreamExtractor` streams only
  the chosen entry into a fresh working copy named by a new identifier,
  bounds output by the declared size and compression ratio, verifies the
  CRC-32, and refuses encrypted, linked, directory, and unsupported entries.
- **Import preview** — analyzed packages wait under **Ready to Import** with
  icon, name, bundle ID, version and build, size, framework and extension
  counts, and signing state. Each can be deselected; nothing is stored until
  the user imports, and deselected packages are skipped. An item whose bytes
  match another item in the hub is deselected with a note.
- **Duplicate Resolution Center** — conflicts with the library are collected
  in the preview instead of being asked one import at a time. Each shows the
  existing entry beside the incoming package (icon, version and build, size,
  import date) with a per-conflict **Keep Both / Replace Existing / Skip**
  choice, **Apply to All**, and **Use Suggested Choices**. Importing stays
  disabled until every selected conflict has a choice.
- **Smart import rules** — `ImportRules` over `DeclaredVersionOrder`
  (numeric-aware: `1.10` > `1.9`, `1.2` = `1.2.0`, `1.0b1` < `1.0`): a newer
  version suggests Replace, identical bytes suggest Skip, an older version
  suggests Keep Both, and the same version with different bytes — or
  versions that cannot be ordered — suggest nothing. A different app imports
  without a question. Suggestions are only applied by an explicit action,
  and "Replace Existing" removes exactly the entries the user was shown,
  after the new entry is stored. Nothing is ever overwritten silently.
- **Automatic analysis** — right after validation, `ImportWorkflow` reads
  the icon, identity, signing state (presence of a `_CodeSignature` seal and
  an embedded profile — worded as present, never as valid), framework and
  extension counts, minimum OS, devices, file count, and unpacked size
  (`ApplicationAnalysis`), shown in the preview and in each item's details.
  On admission the icon cache is primed, so the Library card shows the icon
  at once, and the new record is handed to `SigningDiagnosticsService` at
  utility priority, as the one-shot import does. App Details keeps its own,
  fuller inspection of the stored package; the hub adds no second copy of
  the same facts there.
- **Background behaviour, stated honestly** — imports run while ZynSign is
  open. When ZynSign leaves the foreground the hub asks iOS for its short
  background-task extension (`UIKitImportBackgroundExecution`); if that
  expires, running items pause (keeping any complete working copy) and
  resume when the scene is active again. The hub says exactly this.
- **Import summary** — Imported / Skipped / Replaced / Failed counts
  (`ImportSummary.count(of:)`), Retry Failed, Open Library, and Clear
  Finished. Failed items show the reason, Retry, and a Details sheet with the
  stage they reached.
- **Import history** — each finished batch is recorded
  (`ImportHistoryEntry`, `FileImportHistoryStore`, newest first, 100
  entries) with its time, source, per-item outcome, replacements, and failure
  reasons, and imported apps can be reopened from it. It stores names and
  record identifiers only, stays on the device, and can be cleared.
- **Storage safety** — originals are only read; every step works on an
  isolated working copy. Before any copy, `ImportStorageGuard` checks the
  volume's free space for important usage (`VolumeStorageCapacityProbe`)
  against the copy's size, 100 MiB of headroom, and every copy still
  running, and refuses with a Free Up Space explanation. Unfinished items are
  journaled (`FileImportRecoveryJournal`, names and identifiers only); at the
  next launch an item whose working copy survived resumes from it, others
  are explained as interrupted, and every other working copy is swept.
- **Responsiveness** — preparation and hashing run off the main actor;
  `ApplicationLibrary.describeStagedArtifact(_:)` hashes a working copy on
  the item's own task instead of inside the library actor; progress reaches
  the main actor at most ten times a second per item; icons decode off the
  main thread and are cached.
- **Accessibility and iPad** — Dynamic Type (scaled icons, stacked layouts at
  accessibility sizes), VoiceOver labels, values, custom actions, and a
  completion announcement, Dark Mode through semantic colours, compact and
  regular widths, an **Import** menu (⌘I, ⌘O, ⌘Y) plus ⌘↩ to import, ⌘R to
  resolve conflicts and Esc to close in the hub, context menus on every item
  and swipe actions on queued and finished items, and Reduce Motion
  respected.
- Tests: `ImportHubTests` (entry point, concurrency limit, independence,
  monotonic progress, preview gate, deselection, ordering, identical items,
  collected conflicts, Apply to All, suggestions, summary buckets, cancel,
  retry, storage failures, archives, history, journal, recovery, background
  pause and resume, batching, unreceived drops), `ImportWorkflowTests` (real
  intake, reader, extractor, and library store on disk), `ZipEntryStreamExtractorTests`,
  `PackageContainerClassificationTests` (classification and analysis),
  `ImportRulesTests`, `ImportQueueStageTests` (stages, estimates, storage
  policy and guard), `ImportJournalStoreTests`, and new cases in
  `ImportQueueRenderingTests` and `SecurityScopedArtifactIntakeTests`.

### Changed — Step 13

- `ApplicationEnvironment.packageImportQueue` is now `importHub`; the
  environment also carries `droppedFiles`. `ApplicationLibraryModel`,
  `ApplicationLibraryView` (Step 12's library, unchanged apart from the hub
  and its drop targets), `HomeView`, `FilesView`, and `RootView` observe or
  feed the hub.
- At launch the shell runs the user's temporary-data cleanup first (only
  when the Settings policy asks for it, and only for data older than an
  hour), then sweeps the drop inbox, then lets the hub restore interrupted
  imports, so restoration never races the cleanup. Returning to the
  foreground refreshes the app lock and resumes paused imports in the same
  scene-phase handler.
- `SecurityScopedArtifactIntake` no longer clears the staging directory
  before its first staging; the hub sweeps it at launch with
  `sweepStagedDocuments(keeping:)` after deciding what can resume. The intake
  holds no mutable state, so concurrent items can share it, and it now
  implements `ImportStagingArea` (`stageArchiveEntry`, `stagedByteCount`).
- `ApplicationLibrary` gained `describeStagedArtifact(_:)`,
  `admit(_:describedBy:policy:)`, and `duplicateReport(for:describedBy:)`;
  the existing entry points behave as before.
- `ImportSettlement.Kind` gained `skipped`, and every kind maps to an
  `ImportOutcomeBucket`; `ImportSummary` gained `skippedCount` and
  `count(of:)`. `ImportFailure` is also an `Error` and gained the hub's
  refusals (insufficient storage, corrupted archive, no packages,
  unsupported layout, unsafe archive, interrupted).
- `ImportPreflight.validate` accepts containers when asked
  (`acceptingContainers:`); the one-shot `IPAPackageImport` still accepts
  packages only. `IPAFileFormat` gained the container policy.
- `AppIconExtraction` gained `remember(_:for:)` for icons the hub already
  read.

### Removed — Step 13

- `PackageImportQueue`, `ImportQueueView`, `PackageImportQueueTests`, and the
  `SyntheticImporting` test double, superseded by the hub.

### Added — 0.1.0-alpha.2 · Step 12: Advanced Library Experience

- **One index behind the whole Library** — `LibraryIndex` holds every entry
  with the facts the screen searches, filters, sorts, and counts by: folded
  search text per field, collection membership in both directions, the
  latest declared version of each bundle identifier, and each entry's
  signing fact. Typing, toggling a filter, or changing the order runs a
  query over precomputed values and publishes only the list of visible
  identifiers; a favourite toggled, apps moved between collections, or an
  app opened re-reads just what changed from persistence and patches the
  index instead of reloading the library. Rows and cards are equatable
  values, so a change to one entry re-renders that entry; the list stays a
  virtualised `List` and the grid a `LazyVGrid`.
- **Favorites** — one tap from the detail screen's star (and the leading
  full swipe, the context menu, and a VoiceOver action); a **Favorites**
  card on Home (tap an app to open it, *See All* opens the library on
  Favorites); a Favorites filter and smart collection in the Library; the
  mark stays in the catalog as before. The card star is a small corner mark.
- **Collections** — create, rename, and delete collections; put any number
  of apps into one at once (from a selection, a context menu, or while
  creating the collection); take apps out without deleting them; an app can
  be in any number of collections. Moving from inside a collection moves;
  from anywhere else it adds. Names are normalised, limited to 60
  characters, and unique ignoring case, diacritics, and width, checked as
  they are typed. Deleting a collection is confirmed and never deletes its
  apps; deleting an app removes it from every collection.
- **Smart collections** — **Recently Imported** (last 7 days), **Recently
  Signed** (successful ZynSign signings in the last 7 days), **Unsigned**,
  **Expiring Soon**, and **Favorites**, computed on demand from the index so
  they update themselves. *Expiring Soon* lists apps whose most recent
  ZynSign signing used a provisioning profile or certificate that expires
  within 30 days — or already has — the same window the Profiles tab uses.
- **Advanced search** — every word must match somewhere in the name, bundle
  identifier, version or build, original file name, declared developer,
  declared team (name or identifier), or the name of a collection the app is
  in; case, diacritics, and character width are ignored. Matches are
  highlighted in the row as you type, and a match in a field the row does
  not show (developer, team, file name, collection) is explained on its own
  line.
- **Declared developer and team** — `ApplicationProvenanceExtraction` reads,
  read-only and within small bounds, the team a package's
  `embedded.mobileprovision` declares (`TeamIdentifier`, `TeamName`) and the
  developer its `iTunesMetadata.plist` declares (`artistName`). Values are
  sanitised, shown as declarations rather than findings, resolved in the
  background a few packages at a time after the list is on screen, and
  cached per artifact in the caches directory.
- **Stackable filters** — Favorites, Signed, Unsigned, Recently Imported,
  Recently Signed, Expiring Soon, Collection, Version (latest or older
  versions of each bundle identifier), and Team. Filters on different facets
  must all hold and filters on one facet are alternatives, so *Favorites +
  Unsigned + Recently Imported* narrows while two collections widen. Active
  filters show as removable chips with *Clear All*; the filter menu asks the
  system to stay open while filters are stacked.
- **Seven orders, remembered** — Recently Imported, Recently Signed, Name
  A–Z, Name Z–A, Version, Size, and Last Opened (recorded when an app's
  details open). The preferred order and the last scope are remembered
  across launches; the stored value of the original Name order still reads
  as Name A–Z.
- **Library statistics** — Total Apps, Favorites, Signed, Unsigned,
  Collections, and Storage (bytes the package files occupy: recorded size
  when available, observed size when inconsistent, nothing when missing),
  derived from the index so they update with the list. Each tile is a
  shortcut to the matching scope, filter, or order.
- **Bulk actions** — while apps are selected a floating bar offers Select
  All / Deselect All, Favorite (or Unfavorite when all are), Move to
  Collection, Export, Verify, Remove from Collection (inside a collection),
  and Delete; it exists only while something is selected. The selection can
  only ever hold apps on screen — a filter or search that hides an app
  removes it from the selection — so a bulk action never touches something
  the user cannot see. Deletion is confirmed; one bulk operation runs at a
  time, with progress.
- **Quick actions** — View Details, Favorite, Sign, Verify, Export, Move to
  Collection, collection membership toggles, Remove from Collection, and
  Delete on every row and card: as swipe actions (leading Favorite / Sign /
  Verify, trailing Delete / Move / Export), as context menus, as the detail
  screen's Actions menu, and as VoiceOver custom actions.
- **Verify** — `ApplicationLibrary.verifyArtifact(recordWithID:)` re-reads a
  package file in full and compares its size and SHA-256 fingerprint with
  what was recorded at import: *intact*, *changed since import* (caught even
  when the size is unchanged), or *missing*. It runs off the library actor,
  repairs nothing, and is reported per app with a summary.
- **Export** — `LibraryExportPreparation` hands the share sheet readable
  names (`Name 1.2 (34).ipa`, made safe and unique) as hard links to the
  library's files (copies only where a link cannot be made); apps without a
  package file are skipped and counted, and the prepared names are discarded
  when the sheet closes. The library's own files are only ever read.
- **Empty states** — *No Favorites — Star your favorite apps to find them
  quickly.*, *No Collections — Create your first collection to organize your
  library.*, *No Search Results — Try a different name, bundle ID, or
  filter.*, plus a rule-explaining state for every other smart collection
  and an empty-collection state.
- **Accessibility** — rows and cards read as one element with every badge in
  words; selection changes and outcomes are announced; every quick action is
  a VoiceOver custom action; tap targets are at least 44 points; statistics,
  chips, and grid columns scale with Dynamic Type, and the bulk bar drops its
  captions at accessibility sizes; ⌘A selects all, Esc leaves selection,
  ⌘⌫ deletes the selection, ⇧⌘N creates a collection.
- **Built to grow** — collections are identified values that refer to
  records by identifier, carry creation and change times (and each
  membership its own time), and carry a kind, so tags and shared collections
  are new kinds rather than a new model; a `LibraryQuery` (search, stacked
  filters, order) and a `LibraryScope` have stable codable forms that saved
  searches, pinned workflows, and automations can store.
- `LibraryOrganizationTests`, `LibraryOrganizerTests`, `LibraryIndexTests`
  (including a thousand-entry correctness test and a 2,000-entry query
  measurement), `LibrarySigningFactsTests`,
  `ApplicationProvenanceExtractionTests`, `LibraryArtifactVerificationTests`,
  `LibraryExportPreparationTests`, `ApplicationLibraryAdvancedModelTests`,
  and `SigningJournalTests` (the Sign screen's journal record and the
  notifying journal).

### Changed — Step 12

- **Sign-screen runs are journaled.** The Sign screen runs the Signing
  Engine, which keeps no history, rather than `SigningOperationCenter`, which
  does — so no run started there reached the signing journal, and neither
  Signing History nor the library's *Signed* badge could reflect it. Each
  run now starts a `SigningEngineJournalDraft` (entry, certificate
  fingerprint and name, the profile's declared name, and both expiry dates)
  and appends the completed record — signed, failed, or cancelled — through
  a new `onFinish` hook on `SigningEngineModel.run`. A journal write that
  fails never changes the run's outcome.
- **The journal says when it changed.** The composition root wraps the
  journal in `NotifyingSigningHistoryStore`, which posts
  `signingHistoryDidChange` after every append, removal, or clear — a
  signing, a storage cleanup, or a cleared journal — so the library re-reads
  it without any writer having to remember to post.
- `SigningRecord` gains optional `profileExpiresAt` and
  `certificateExpiresAt`; journals without them decode unchanged. The
  library attributes a signing through the record's existing
  `sourceRecordIdentifier`: a signing that names its record belongs to that
  record alone, and an older entry that names only a bundle identifier is
  attributed to records with that identifier that already existed when it
  ran. `BatchSigningCoordinator` records the signed record too.
- `LibraryArtifactStore` gains `measureHeldArtifact(_:)` (implemented by the
  file store with the same streaming SHA-256 import uses).
- `ApplicationLibraryModel.SortOrder` is now `LibrarySortMode`; `.name` is
  Name A–Z. Version order compares the marketing version and then the build,
  with undeclared versions last.
- Collections and usage live in a new versioned document,
  `Application Support/ZynSignLibrary/Organization.json` (schema 1), so
  rearranging collections or opening an app never rewrites `catalog.json`.
- **Release gating** — everything above is behind
  `ReleaseFeature.libraryPowerFeatures`; parts that read the signing journal
  (Signed, Unsigned, Recently Signed, Expiring Soon, Sign) also need
  `smartSign`. `ReleaseTrain.swift` currently introduces
  `libraryPowerFeatures` in `v0.1.0-alpha.1`. Debug builds show everything.

### Added — 0.1.0-alpha.1 · Step 11: Settings, Security & Configuration Center

- **Settings Control Center** — Settings is an index, not a form. Every
  preference lives in its own section, reached from the hub, and every section
  is a peer of every other: a section declares its own descriptor
  (`SettingsSectionDescriptor`) and registers itself in one catalog entry
  (`SettingsSectionCatalog`), so a later version adds, reorders, or extends a
  section by adding a file rather than by editing a switch. The hub knows a
  section's title and where it goes, and nothing about what is inside it.
  Sections: General, Signing, Security, Storage, Diagnostics, Appearance,
  Advanced, Recovery, About.
- **One preferences model, one write path** — `ZynSignPreferences` holds seven
  independent groups behind `FilePreferencesStore`, which loads the document
  once at construction (so Settings opens instantly), writes it whole and
  atomically (so an interrupted write can never leave half a preference), and
  never fails on read: a missing or damaged document becomes shipped defaults
  and the reason is kept for Diagnostics. Decoding is group by group, so a
  document written by another version — or one group's shape changed by a later
  build — costs the user the settings in that group and nothing else. The two
  keys an earlier version kept in `UserDefaults`
  (`zynsign.appearance.colorScheme`, `zynsign.onboarding.completed`) are
  migrated once, written out, and removed; archive options the Archive screen
  still reads stay where they are, so no setting has two owners.
- **General** — default landing tab (switches tabs now and on next launch),
  haptic feedback, animation preference (Standard / Reduced / Off, with the
  system's Reduce Motion always winning), language readiness reported honestly
  as English-only rather than offered as a choice, and reset onboarding as its
  own action.
- **Signing Preferences** — preferred signing identity (named by its public
  certificate fingerprint), preferred provisioning profile (named by the name
  the profile declares), remember previous selections, and automatic
  compatibility analysis. Every value is a *starting point*: the signing
  screen presents it and the user may choose something else for that session.
  Nothing here holds signing material.
- **Security Center** — Face ID / Touch ID protection where the device offers
  it (and a plain statement where it does not), authentication before
  sensitive actions with the list of those actions, secure session timeout
  (immediately / 1 / 5 / 15 minutes), and sensitive-data visibility
  (hidden / masked / visible) with a live preview. `AppLockController` owns
  the lock and `BiometricAuthenticating` is the only boundary through which
  ZynSign asks the system: it learns whether an attempt succeeded and nothing
  else. Private key material is never exposed through Settings, never
  exported, and never logged — it stays in the Keychain, marked
  non-extractable.
- **App lock in the shell** — a locked ZynSign shows one full-screen overlay
  (Unlock), is unlocked by the attempt that needs it, and locks when it is
  backgrounded with protection on or when the session lapses. A preference to
  lock on a device that cannot authenticate is not enforced, and the Security
  Center says so instead of showing a switch that does nothing.
- **Storage Manager** — a dashboard over the application's own storage use
  case, reporting allocated bytes per category (Imported Apps, Signed
  Artifacts, Temporary Files, History) with a total that is the sum of the
  rows rather than an estimate, and three actions — clear temporary files,
  remove signed artifacts, remove old history records — each behind a
  confirmation and each reporting what it removed and how much it reclaimed.
  Cleanup is age-based for temporary data, so an operation running right now
  is never a candidate, and it counts what it skipped rather than staying
  quiet about it. No action on this page can reach an imported application:
  removing one is a Library action, one application at a time.
- **Diagnostics Preferences** — keep diagnostic history, detailed technical
  logs (opt-in, off by default), developer diagnostics that change what the
  page shows rather than what ZynSign does, a readable technical log, and
  export diagnostic report. The
  report is counts, versions, and preference flags: no bundle identifier, no
  file name, no path, no certificate detail, no key material. It is written to
  a file the user shares themselves; nothing in ZynSign sends it anywhere.
- **Appearance** — System / Light / Dark applied at the root, increased
  contrast through the environment, and Dynamic Type reported as supported
  rather than offered as a second, competing text size. One theme ships, and
  the identifier is stored so a later release can add themes without changing
  anything else the user chose.
- **Advanced** — working-directory behaviour, temporary-file cleanup policy,
  verification strictness, and experimental feature flags. It is listed apart
  from everyday settings and says why. `ExperimentalFeature` has no cases,
  because a flag appears only once the feature behind it is implemented and
  reachable; the section says exactly that instead of listing switches that do
  nothing.
- **Recovery** — reset preferences (keeping the record of finished
  onboarding), clean temporary workspace, and rebuild library index, each
  asking first and reporting what it did. Reset Library is the one
  destructive reset in the application: it is labelled as such, it names
  exactly what will be deleted, and it asks twice — once with a confirmation
  and once through authentication when the user asked for authentication
  before sensitive actions. Preferences are configuration, so resetting them
  asks for no fingerprint.
- **About** — version, build, the app's own mark drawn from the design
  system, copyright, open-source licences, privacy policy, terms of use, and
  acknowledgements, all as documents that ship with the application rather
  than links to a server that learns you read them. Nothing on the page
  describes how ZynSign was made.
- **Accessibility as a first-class part of the settings system** — every row
  carries a label and a symbol, every control is a real control with a large
  enough target, Dynamic Type is inherited from the system everywhere, the
  animation preference is honoured on top of Reduce Motion, and the lock
  overlay is announced as modal.


### Added — 0.1.0-alpha.1 · Step 8: IPA Explorer & Bundle Browser

- **Read-only IPA explorer** — `Explore IPA` opens a native tree of the
  package already in the library: `Payload/<App>.app`, folders, frameworks,
  extensions, and files, with type labels and declared sizes. Expanding a
  folder does not read the files inside it. A large folder shows one page
  and a control for the next. iPad uses a split view; iPhone uses a stack.
- **Search and resources** — filename, extension, and immediate folder-name
  search, with the match highlighted and the display capped while the total
  stays accurate. A resource browser lists images, JSON, XML, localization
  folders, and launch assets from the same entry table.
- **Bounded previews** — opening a file reads that entry only, through the
  existing archive boundary, and closes the reader afterward. Text, JSON,
  XML, property lists, and images can be shown. A larger image is refused
  and not read. A symbolic link is listed and not followed. Nothing in the
  explorer modifies, extracts, signs, or runs the package.
- **Mach-O, framework, and extension pages** — a Mach-O page is a header
  prefix: architecture, file type, load-command count, encryption-command
  status, and signature-command presence. It is not a hex dump and not a
  verdict. Framework and extension pages show the name, version when the
  information file yields it, the executable, and a path back into the tree.
  Extension entitlements are the embedded profile's declared keys, not a
  device list and not a verification.
- **Statistics and actions** — the card counts files, frameworks, extensions,
  executables, images, and the declared bundle size. The only actions are
  View Details, Reveal in Tree, Copy Path, and Copy Filename. Copy copies
  the package-relative path, not a sandbox URL.

### Added — 0.1.0-alpha.1 · Step 7: Signing Engine Execution

- **One execution engine** — `SigningEngineCoordinator` runs a complete
  signing attempt behind a single call and answers with a structured result:
  every stage's outcome, the run's summary metrics, both verification reports,
  the working copy's facts, or the stage that refused with a typed reason and
  the recovery facts. Stages are named once, in `SigningEngineStage`, and the
  coordinator, the progress tracker, the diagnostics, and the interface all
  use that one vocabulary.
- **The original package is never signed** — every write happens inside an
  isolated `SigningWorkingCopy` under the configured root. The original is
  fingerprinted (SHA-256) when the copy is made and re-measured when the copy
  is discarded, so "original unchanged" is a measurement. Discarding reports
  the items and bytes reclaimed, and the source container is only ever read
  through the ordinary read-only archive boundary.
- **Validation gate before signing** — `SigningEngineBundleValidator` checks
  the payload layout, the information file, the declared executable, the
  required files, every location nested discovery found (each with a readable
  information file and a recorded executable), and the supported layout —
  including refusing inputs that already carry a signature under the run's
  policy. A failed check stops the run at Validating with nothing written.
- **Inner-first nested signing** — Frameworks, then dynamic libraries, then
  extensions, then nested applications, then the host application, each stage
  reported separately and skipped-with-reason when a bundle carries none of
  that kind. The underlying plan keeps a child finalized before its container;
  the host executable is sealed and signed last, with the seal referencing
  every nested binary by digest.
- **Independent verification, twice** — `SigningEngineVerifier` re-reads the
  signed working copy and re-derives the CodeDirectory facts, the page hashes,
  the special slots (seal in slot 3, canonical entitlements in slot 5), the
  embedded entitlements, and the CMS signature under the certificate resolved
  at verification time, plus bundle consistency and provisioning
  compatibility; `VerifySignedApplication` then re-reads the *written
  container* through the archive boundary. Neither shares state with signing,
  and neither claims trust or installability.
- **Delivery only after verification** — the IPA is packaged in the pipeline's
  deterministic `Payload/` form into a scratch path inside the working copy,
  verified there, and moved to the delivery location only after it passed. A
  failed run leaves an artifact already at that location untouched and reports
  that it existed; a verification failure removes nothing but the working
  copy.
- **Progress that is a fact, not a spinner** — `SigningEngineProgressTracker`
  keeps one record per stage (state, item counts, latest detail) and a
  fraction whose weights sum to `1`. An estimate is offered only after enough
  of the run has happened (10% and 0.4 s) for a projection to mean something.
  The tracker is I/O-free and clock-free — callers pass elapsed time in — so
  the behaviour is testable without waiting.
- **Failure recovery** — a refusal returns the stage, a bounded detail, a
  category, a user message, and the recovery facts (original unchanged,
  working copy discarded, output removed, output pre-existed), with retry
  offered only for input faults where a second attempt cannot help.
  Cancellation propagates as `CancellationError` after the working copy is
  discarded; a partially signed bundle is never left where it could look
  complete.
- **One signing screen** — `SigningView` drives the engine end to end: stage
  rows with live counts, the fraction ring, the estimate when it exists,
  stage-scoped failure diagnostics, and the export actions — **Export IPA**
  (share sheet), **Open Details** (`SigningDetailsView`: stage table,
  verification checks, recovery facts), **Verify Again** (re-runs container
  verification, never deletes), and **Return to Library** — with semantic
  fonts, VoiceOver stage summaries, and Dark Mode tokens.
- `SigningEngineCoordinatorTests`: end-to-end delivery with every stage's
  outcome and both verification reports, nested-framework runs, refusal of an
  already-signed input before signing, refusal of a bundle with no information
  file, an artifact already at the delivery location surviving a failed run,
  the working copy being discarded on success and on failure, monotonic
  progress with a complete final snapshot, and verifying a delivered container
  again — including after it is tampered with.

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
