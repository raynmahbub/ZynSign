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

- **Store and Downloads are shell destinations at every stop.** `ShellSection`
  keeps all six tabs; `primaryTabs(where:)` exempts `.appStore` and `.downloads`
  from the gate, and `RootView.visibleSelection` still clamps a saved landing
  preference to a tab the stop shows. See *Gate drift this stop introduces*.
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

- **Profile picker failures are announced.** `ProvisioningProfilesModel` returned
  early on every non-`.success` picker result; only cancellation stays quiet now,
  and any other failure raises a typed notice.
- **`generate_changelog.py` no longer overwrites curated release notes.** The
  publish job hands `docs/releases/notes-v<version>.md` to
  `gh release --notes-file` *after* running the script, so an unconditional write
  replaced this file's contents in the published Release. A curated
  `[Unreleased]` entry is now promoted verbatim into the versioned section, and
  the commit-log scrape runs only when `[Unreleased]` is empty.

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
and `ShellSectionTabTests.testDevelopmentStopKeepsStoreAndDownloadsDiscoverable`
(replacing `testDevelopmentStopShowsOnlyTheCoreTabs`, which asserted the old
policy). **Their results belong to CI** — the `Build and test (Xcode)` job is the
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
