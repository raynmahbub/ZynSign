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

**Development 3.** Market `0.0.1`, tag `v0.0.1-dev.3`, release train `.dev3` —
the last development stop, and it switches on no staged `ReleaseFeature` of its
own (`ReleaseStage.dev3.introducedFeatures` is empty). What the stop carries is
everything merged since the `v0.0.1-dev.2` tag: the Settings index rebuild, the
shell decision to keep primary navigation open at every stop, the clearer
picker and repository failures behind it, and the release machinery that
publishes the notes for the stop being cut. The `CFBundleVersion` is assigned by
`python3 Scripts/release_train.py promote` rather than claimed here. Notes:
[`docs/releases/notes-v0.0.1-dev.3.md`](docs/releases/notes-v0.0.1-dev.3.md).

> **Gate drift to settle before the tag.** `dev.2` closed the gate on four entry
> points; keeping Store and Downloads discoverable opened them again on purpose.
> `certificateStudio`, `provisioningProfileManager`, `appStore` and `downloads`
> no longer have a live check anywhere in the Presentation layer: each is still
> declared on `ShellSection.requiredFeature`, but `primaryTabs(where:)` returns
> `true` for the Store and Downloads before consulting it, and Settings → Signing
> offers the Certificates and Profiles rows unconditionally. A Release build at
> `dev.3` therefore exposes four areas the train assigns to `v0.1.0-alpha.1`
> (Certificate Studio), `v0.1.0-alpha.2` (Provisioning Profile Manager) and
> `v0.1.0-alpha.3` (App Store, Download Center). Either re-gate the staged
> *actions* behind each tab, or move these four surfaces into `v0.0.1` and let
> the alphas keep what they actually switch on — but the code and
> `docs/releases/release-train.md` have to agree before the tag is cut.

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
  platform that cannot still produces a working, verified identity.
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


## [0.1.0-alpha.3] - 2026-09-29

**Alpha 3.** Market `0.1.0` build `2` (`CFBundleShortVersionString 0.1.0`,
`CFBundleVersion 2`), tag `v0.1.0-alpha.3`, release train `.alpha3`. Notes:
[`docs/releases/notes-v0.1.0-alpha.3.md`](docs/releases/notes-v0.1.0-alpha.3.md).

Switches on **ten** staged features, seven of them first reachable in a Release
build: Certificate Studio, Library Power Features, Smart Sign, the Provisioning
Profile Manager, the Professional Signing Queue, Intelligent Signing Presets,
the App Store with repository health, the Download Center, the Entitlements
Studio, and the Developer Identity Center.

Mission Control, the installation delivery hand-off, and the local activity
journal remain staged for `beta1` and are reachable in Debug only. The three
recorded *never* — in-app installation, pairing/JIT/mux, and off-device
analytics — are unchanged and are still not offered by any release.

### Fixed

- **Settings crashed on open.** `FilesView`, `AppStoreView` and `DownloadsView`
  each embedded a `NavigationStack` while being pushed as a `NavigationLink`
  destination from inside Settings' own stack. Nesting a stack inside a pushed
  destination crashes at runtime. All three now take an `embedsNavigationStack`
  flag, following the pattern `PresetsView` already used.
- **Two more crashes of the same class**, found by the new audit and closed:
  `ProfilesView` and `InstallationWorkspaceView`, both pushed from Settings →
  Browse. The second had been dormant only because its feature was gated off;
  promoting to `alpha3` would have activated it.
- **The Import button could silently do nothing.** It asked for a file picker
  400 ms after asking for the Import Hub, losing the request whenever the sheet
  took longer to present. It is now presented off the sheet's own appearance.
- **`audit_navigation_stack.py`** refuses a pushed destination that opens its own
  navigation stack, and runs in the hygiene job.

### Changed

- **The tab bar is `Files · Library · Home · App Store · Downloads · Settings`**
  and is no longer subject to the release gate — a tab that appears and
  disappears between releases is one a user cannot rely on. Certificates and
  Profiles left the tab bar and are reached from Settings; a stored landing tab
  naming one of them coalesces to Library rather than selecting nothing.
- **Home is a command center**: the wordmark, three counts that open the area
  they count, an updates row that appears only when something is ready, the
  import target, a direct-link field, and the action list. A count that has not
  been read shows a neutral block rather than a zero, so "none" and "not loaded"
  never look alike.

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
