# ZynSign `v0.0.1-dev.3`

Market `0.0.1` · build `4` *(to be assigned — see below)* · channel
**development** · pre-release.

The build number is **not** in the tree yet: `ReleaseTrain.current` is still
`.dev2` and `ZynSign.xcodeproj/project.pbxproj` declares `MARKETING_VERSION 0.0.1`
/ `CURRENT_PROJECT_VERSION 3`. `python3 Scripts/release_train.py promote` writes
`.dev3`, `0.0.1` and build `4` in one step, and the private build is made from
that same commit — nothing here claims a build that has not been produced.

## What this stop is for

Third and last rehearsal before the first build (`v0.0.1`). A development stop
switches on **no** staged feature — `ReleaseStage.dev3.introducedFeatures` is
empty — so its whole job is to run the machinery against a real tag one more
time: quality gate → build + tests → version-stamped assets → publish, with the
private device matrix green before anything is public.

What it ships in practice is everything merged since `v0.0.1-dev.2`: the Settings
index rebuild, the shell's decision to keep primary navigation open at every
stop, clearer picker and repository failures, a shorter launch transition, and a
fix to the release pipeline's own notes handling.

`dev.3` is also the last stop where the gate can be proven before `v0.0.1` puts a
real feature surface in front of users, so the rehearsal has to say so out loud:
a Release build at this stop shows the core **plus** the App Store and Downloads
tabs, which `dev.2` had cut.

### Gate drift this stop introduces

Keeping those tabs open did not only move navigation. In the tree as merged,
`certificateStudio`, `provisioningProfileManager`, `appStore` and `downloads`
have **no live gate left in the Presentation layer**:

- `ShellSection.primaryTabs(where:)` returns `true` for `.appStore` and
  `.downloads` before it consults `requiredFeature`, so `requiredFeature` now
  governs only Presets and the Installation Workspace.
- Settings → Signing offers the Certificates and Provisioning Profiles rows
  (import *and* management views) with no `ReleaseTrain.isAvailable` check.
- The only remaining checks for `.downloads` / `.provisioningProfileManager`
  sit inside `Presentation/Nova/SmartWorkspaceView`, which no app code presents
  (recorded as a dead view in [`../product/FEATURE_STATUS.md`](../product/FEATURE_STATUS.md))
  — so they gate nothing a user can reach.

So a Release build at `dev.3` exposes four areas that
`docs/releases/release-train.md` assigns to `v0.1.0-alpha.1` (Certificate
Studio), `v0.1.0-alpha.2` (Provisioning Profile Manager) and `v0.1.0-alpha.3`
(App Store, Download Center). `dev.1` had exactly this problem and `dev.2`
closed it; the shell change has opened it again.

That is a product decision the shell change made implicitly, and it has to be
made explicitly before the tag: re-gate the staged actions behind each tab, or
move these four surfaces into `v0.0.1` and let the alphas keep only what they
actually switch on. The gate map in [release-train.md](release-train.md) and the
counts in [../product/FEATURE_STATUS.md](../product/FEATURE_STATUS.md) now
describe the tree as it is; the decision itself is still open, and this note does
not pretend it was made.

### Added

- **Searchable, reorderable Settings** *(visible from `dev.3`; not a staged
  capability)* — ten categories (Signing, Updates, General, Devices, Servers,
  Miscellaneous, Diagnostics, Reset, About, Socials), each routing to a flow that
  already existed. Search filters the categories and their rows, an empty result
  renders `ContentUnavailableView.search`, and drag-to-reorder persists to
  `zynsign.settings.categoryOrder`. No architecture page describes Settings — the
  behaviour lives in `ZynSign/Presentation/SettingsView.swift`.
- **Repository quick-add** *(visible from `dev.3`)* — the Store's empty state
  separates *No Repositories Yet* from *No Matching Repositories* and offers
  **Add Repository** inline; the add sheet accepts a **Paste Repository URL**
  action. See [`../architecture/store-browser.md`](../architecture/store-browser.md).

### Changed

- **Store and Downloads are shell destinations at every stop.**
  `primaryTabs(where:)` exempts `.appStore` and `.downloads` from the gate, and
  `RootView.visibleSelection` still clamps a saved landing preference to a tab
  the stop shows. The bar they land in is capped at five items
  (`ShellSection.tabBarItemLimit`), so a build with every gate open shows
  Files · Library · Home · Store · Settings and folds Downloads into the surface
  that already opens it. See *Gate drift this stop introduces*.
- **Certificate and profile surfaces are open at every stop.** Settings → Signing
  leads to `.p12` / `.pfx` and `.mobileprovision` import *and* their management
  views without a stage check; the signing, identity-center, preset and
  installation workflows they feed remain behind their stops.
- **"Source" → "repository"** across the Store (`Manage Repositories`,
  `Add Repository`, `Validate & Add Repository`, matching accessibility label).
- **Import wording** — *Add N Apps to Library*, plus an explicit statement that
  selecting a file only previews it.
- **Launch splash** — a single 0.36 s fade (0.18 s under Reduce Motion) with no
  launch haptics, replacing the previous ~1.9 s spring/shimmer sequence.
- **Splash and prominent button text** use `Color.primary` rather than a
  hardcoded white.

### Fixed

- **A `.p12` could never finish importing, and the rule that stopped it asked
  the platform for something it cannot give.** Registration required the
  imported private key to carry `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  and an explicitly reported non-extractability attribute. `SecPKCS12Import`
  takes no attribute dictionary, so its items carry the Keychain's default class
  (`kSecAttrAccessibleWhenUnlocked`), and iOS has no supported way to re-protect
  a private key after creation — `SecItemUpdate` on `kSecAttrAccessible` needs
  the item's data, which a private key never returns. Every identity the
  platform could legally produce for an import was refused with *The required
  identity protection is not available*, no matter what the user did.
  `SigningKeyProtectionRule` now requires the property signed identities depend
  on — a private key, never synchronizable, unreadable while the device is
  locked, and not reported as exportable — and is pinned by
  `SigningKeyProtectionRuleTests`. `ApplePKCS12Importer` additionally asks for
  the device-only class before registering and does not assume the answer; the
  resolver reads the key's actual attributes back, so a platform that honours
  the upgrade gets device-only protection and one that cannot still produces a
  working, verified identity. The rule is a pure type, exercised by the ordinary
  test suite rather than only by the opt-in signed-host Keychain test, and that
  test's fixture was corrected: it asked for `kSecAttrIsExtractable` inside
  `kSecPrivateKeyAttrs`, where the platform ignores it, so it built an
  exportable key — the one shape the resolver refuses.
- **An Open In or share-sheet hand-off could be received and never shown.** The
  presentation was requested in the frame ZynSign returns to the foreground,
  where UIKit drops it with no error, and the state that asked for it stayed
  set — the Import Hub, certificate sheet, or profile sheet never opened, and
  asking again changed nothing. The shell now holds the request and honours it
  the moment the scene is active.
- **A package picked inside Files never reached the Import Hub.** `FilesView`
  handed the package to the hub and asked the shell to present it in the same
  frame the document picker was still dismissing. It waits the same settle every
  other post-picker presentation waits (`PresentationSettle`), so the hand-off
  lands instead of leaving the hub closed with the package queued behind it.
- **An environment default could build a second application graph.** The
  defaults for `\.applicationEnvironment`, `\.settingsCenter`, `\.appLock`,
  and `RootView`'s environment argument each constructed a complete
  `ApplicationEnvironment` — stores, caches, schedulers, and the recovery pass —
  on first read. They now share one fallback built at most once per process
  (`CompositionRoot.fallbackEnvironment`), and `RootView` takes its environment
  as a required argument, so no screen can silently render a second library and
  a second set of preferences.
- **The Import Hub's *Choose Files* no longer pays a settle beat it does not
  need.** The picker waits the beat only while the hub's sheet is still settling;
  once it has, the picker is raised on the next frame.
- **Profile picker failures are announced.** `ProvisioningProfilesModel` returned
  early on every non-`.success` picker result; only cancellation stays quiet now,
  and any other failure raises a typed notice.
- **`generate_changelog.py` no longer overwrites curated release notes.** The
  publish job hands `docs/releases/notes-v<version>.md` to
  `gh release --notes-file` *after* running the script, so an unconditional write
  replaced this file's contents in the published Release. A curated
  `[Unreleased]` entry is now promoted verbatim into the versioned section, and
  the commit-log scrape runs only when `[Unreleased]` is empty.
- **The bar no longer asks UIKit for a sixth tab.** Six sections were listed and
  a phone tab bar draws five; the sixth went into a system *More* list that
  *pushes* it, and since every tab view owns a `NavigationStack`
  (`RootView.tabContent`) the folded tab nested one stack inside another. Which
  section got folded depended on width and gate state, so one build produced a
  Store tab that was simply absent and a Settings tab that crashed when opened.
  `ShellSection.primaryTabs` now takes the overflow from `tabOverflowOrder`
  (Downloads first) and leaves the survivors in declared order. Locked by
  `ShellSectionTabTests.testTabBarNeverExceedsThePlatformCeiling`.
- **A Home shortcut can no longer select a tab that is not there.** The
  onboarding checklist asked for `.certificates` and `.profiles`, neither of
  which has a slot, and handing `TabView` an unmatched selection leaves the bar
  with nothing highlighted and the content area empty — the exact experience of
  *tapping does nothing*. Every `onOpenSection` request now resolves through
  `ShellSection.tab(toOpen:)`, which routes a slotless section to the Settings
  surface that hosts it.
- **A chosen certificate reaches the password sheet.** `CertificateManagerView`
  raised its password sheet from inside the `.fileImporter` completion — the same
  frame the document picker is still dismissing, where UIKit drops a presentation
  without an error. The file was read, and nothing appeared to happen. The sheet
  is now presented after the settle `RootView.presentSigningQueue()` already
  uses for the same reason.
- **The Import Hub's picker is no longer a one-shot.** `chooseFiles` set a flag
  consumed only by the hub's own `.task`, so a request that arrived once the hub
  was already on screen was never seen, and the single `Task.yield()` was not a
  wait for the sheet's transition. Both orderings now consume the flag, and the
  settle matches the rest of the app.
- **The splash stops being dismissed mid-animation.** The shortened launch
  timeline left its internals on the old schedule: a `repeatForever` glow pulse,
  a shimmer sweep, a footer animating on a `0.9 s` delay and a `2 s` easing, and
  **two** owners of the exit — the view animated itself out *and* `ZynSignApp`
  removed it with a spring and a scale/slide. Removing a layer while its
  sub-animations are still flying is a visible jump, so every stage now lands
  inside the window and the view alone owns the fade out.

### Known limitations

Carried in `ReleaseBlockerRecord.registry` and shown in the Compatibility Lab:

- **In-app installation has no available mechanism.** *(low, accepted — ZynSign
  builds the OTA manifest, install link and QR and hands off; it never claims an
  install, and Settings → Installation keeps the typed assessment.)*
- **Device and iOS matrices need physical-device confirmation.** *(medium,
  open — the Lab executes on the device it runs on and records every other row
  as not run.)*
- **Signing scenarios stop at preparation without signing material.** *(medium,
  open — structure, metadata, nested discovery and plan validation run; an
  actual signature needs an identity and a profile on the device.)*
- **Performance figures measured on a simulator are not device figures.**
  *(low, accepted — they are reported as simulator measurements.)*
- **IPA/tIPA import is still unconfirmed on a device.** The presentation faults
  above cover the picker never appearing, a picked file going nowhere, and a
  hand-off that arrives as ZynSign comes back to the foreground; none has been
  watched working on hardware, and the pipeline behind them is unchanged.
  `ImportablePackage.contentTypes` is deliberately broad (`.data`, `.zip`,
  `.archive`, `.item` and Apple's IPA UTI), so a file the picker cannot see is a
  different bug from the ones fixed here and is not claimed as solved. If a
  device still refuses an `.ipa` or `.tipa`, the Import Hub names the item's
  reason and the failed item's details are the next thing to read.

### What this release deliberately does not claim

- **No staged feature is switched on by this stop.** `dev.3` introduces no
  `ReleaseFeature` at all: signing, presets, the queue, the Entitlements Studio,
  the Identity Center, Mission Control, the delivery hand-off, the journal, the
  Installation Workspace, the performance engine, the Smart Workspace, Batch
  Signing, the health score and Nova stay compiled in and hidden in a Release
  build, reachable in Debug or with `-ZynSignReleaseStage <stage>`.
- **This stop does not claim the gate closes the app.** The four surfaces named
  in *Gate drift this stop introduces* are open in a Release build, which is not
  what the train table says their alpha stops are for. Saying "core only" while
  that is true would be the same error `dev.2` recorded and fixed.
- **No App Store submission, and no install.** Distribution is TestFlight
  internal plus a sideload IPA.
- **No device matrix.** The iOS 17 / iOS 18 rows below are empty because nobody
  has run them; they are not "passing".
- **No signing executed end to end on a device at this stop**, and no off-device
  measurement of any kind — see
  [`../product/WHAT_DOES_NOT_EXIST.md`](../product/WHAT_DOES_NOT_EXIST.md).

### Testing

New unit tests: `ProvisioningProfilesModelTests.testPickerFailureIsSurfacedButCancellationStaysQuiet`,
`ShellSectionTabTests.testDevelopmentStopKeepsStoreAndDownloadsDiscoverable`
(replacing `testDevelopmentStopShowsOnlyTheCoreTabs`, which asserted the old
policy), and `SigningKeyProtectionRuleTests` — the rule that decides whether a
stored signing key may sign, pinning both halves of it: the Keychain's default
class that an imported key actually carries must pass, and every class that
leaves a key readable while the device is locked, plus a key reported as
exportable, must fail. **Their results belong to CI** — the `Build and test (Xcode)` job is the
judge, and this note claims nothing about them until it has run: no macOS
toolchain is available in the environment that wrote these notes, so
`xcodebuild` and XCTest were not executed.

Host audits, run on the machine that produced this note (Linux, Python):

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | pass — 9 constructs, matching the baseline, every one justified |
| `Scripts/audit_accessibility.py` | pass on what a machine can check — 0 hard-coded colours outside `DesignTokens` in the app, 0 controls under 44×44; 6 text nodes may shrink below 0.75 scale (4 waived after review); VoiceOver, focus order and rendered contrast at every Dynamic Type size remain a human device pass |
| `Scripts/audit_regression_coverage.py` | pass — 9 behaviours executed in the app, 2 deferred to CI; every named test type exists |
| `Scripts/audit_navigation_stack.py` | pass — no pushed view opens its own `NavigationStack` |
| `Scripts/audit_design_tokens.py` | pass against `design_tokens_baseline.json` |
| `python3 Scripts/release_train.py check` | pass — the tree declares `.dev2`, which is the stop already tagged |
| `bash Scripts/ci/release_validate.sh 0.0.1-dev.3` | **fails on purpose** — "Releasing tag v0.0.1-dev.3 but `ReleaseTrain.current` is v0.0.1-dev.2". It turns green when `promote` is committed, and that promoted commit is the one to build and test. The changelog warning alongside it is the workflow's job at tag time, now fed by the curated `[Unreleased]` entry |
| `python3 Scripts/update_readme.py --check` | pass — badge reads `0.0.1`, honest line `10 wired · 3 never` |
| `Scripts/ci/docs_check.sh` | pass — 81 pages, 0 errors, 0 warnings; this file is linked from `CHANGELOG.md`, so it is not an orphan |

Device rows: **none.** The private matrix in [`private-testing.md`](private-testing.md)
(one iOS 17 device, one iOS 18 device, plus a simulator smoke) is run against the
promoted commit on the maintainer's Mac, and no row here is filled in from a
simulator run or a wish.
