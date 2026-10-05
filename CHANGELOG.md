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
