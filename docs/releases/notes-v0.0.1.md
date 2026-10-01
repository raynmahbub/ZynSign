# ZynSign `v0.0.1`

Market `0.0.1` · build `5` · channel **stable**, `prerelease: false` · the first
build. `Scripts/ci/release_meta.sh` derives the channel from the version suffix,
and a bare `0.0.1` has none, so this tag publishes as a full GitHub Release and
becomes `latest` — unlike `v0.0.1-dev.1…3`, which the same script marks as
development pre-releases.

`CFBundleShortVersionString 0.0.1`, `CFBundleVersion 5`, tag `v0.0.1`. Release
train `.horizon`: this stop switches on **no** staged `ReleaseFeature` —
`ReleaseStage.horizon.introducedFeatures` is empty — so a Release build shows
the same surface `v0.0.1-dev.3` showed: the five-tab bar (Files · Library ·
Home · Store · Settings, Downloads folded into Settings → Updates by the
platform's five-item ceiling) and everything reached from Settings.

## What this stop is for

`dev.1` proved the pipeline against a real tag, `dev.2` proved it with the
release gate actually closing, `dev.3` was the rehearsal that fixed what the
first two had broken. `v0.0.1` is the stop those three existed to reach: the
first build a user installs rather than a maintainer measures. It carries no
new surface, which is the point — a first build should be the rehearsed one
with the defects taken out, not a new shape nobody has driven.

What it does carry is two reachability fixes in Settings, both of the same
kind: a screen or a choice the tree contained, tested, and could not present.

### Gate drift carried into this stop, not resolved by it

`certificateStudio`, `provisioningProfileManager`, `appStore` and `downloads`
still have no live `ReleaseTrain.isAvailable` check at any reachable entry
point, so a Release build at `v0.0.1` exposes four areas the train assigns to
`v0.1.0-alpha.1`, `v0.1.0-alpha.2` and `v0.1.0-alpha.3`. `dev.3` shipped with
that recorded instead of fixed: re-gating or moving the stops after the tag was
a product-surface change nobody had asked for. The same reasoning holds one
stop later, and the decision is still owed to the `v0.1.0-alpha.1` cut, where
the feature map is written next.

What changed is the weight. This is no longer a rehearsal, so the drift now
sits in a release a user can install, and the two options — re-gate the staged
*actions* behind each surface, or move the four into `v0.0.1` and let the
alphas keep what they actually switch on — are carried forward with that
stated rather than deferred quietly a second time.

### Added

- **Security in the Settings index** *(not a staged `ReleaseFeature` — the word
  `security` does not appear in `ReleaseTrain.swift` at all, so this area is
  always available, which is what made an unreachable row a real loss rather
  than a gate doing its job)* — the row that opens `SecurityCenterSection`: the
  biometric application lock, the session timeout, the
  require-authentication-for-sensitive-actions rule, sensitive-data visibility,
  and per-app Lock and Vault. All of it has been compiled in since before
  `dev.1`; this stop is the first that can reach it, and so the first in which
  `AppLockOverlay` can be armed by a user. Nothing is new in the tree — the
  navigation is. See `ZynSign/Presentation/SettingsView.swift:98`.

### Changed

- **Settings → General's landing-tab picker lists five tabs, not six.** The row
  now offers `ShellSection.offerableLandingTabs` — Files, Library, Home, Store,
  Settings — and reads its stored value back through
  `ShellSection.effectiveLandingTab`, the same fallback launch resolves through.
  A preference saved by an earlier build as *Downloads* now reads as *Library*,
  which is what a launch with that preference actually opens.

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
- **The gate drift above is open, not accepted.** Four surfaces are reachable
  ahead of the stops the train assigns them to. Nothing here hides that or
  works around it; the user gets more than the release table promises, and the
  decision is recorded as owed to `v0.1.0-alpha.1`.
- **Neither fix in this stop has been seen on a device.** Both are reachability
  faults proved from the tree — a `@ViewBuilder` switch with a missing case,
  and a picker offering a tag its own bar cannot select — and both are pinned
  by unit tests rather than by a device run. The private matrix below is what
  would confirm them, and it has not run against this commit.

### What this release deliberately does not claim

- **No staged feature is switched on by this stop.** Signing, presets, the
  queue, the Entitlements Studio, the Identity Center, Mission Control, the
  delivery hand-off, the journal, the Installation Workspace, the performance
  engine, the Smart Workspace, Batch Signing, the health score and Nova stay
  compiled in and hidden in a Release build, reachable in Debug or with
  `-ZynSignReleaseStage <stage>`.
- **This stop does not claim the gate closes the app.** The four surfaces named
  above are open in a Release build, which is not what the train table says
  their alpha stops are for. Saying "core only" while that is true would repeat
  the error `dev.2` recorded and fixed.
- **No App Store submission, and no install.** Distribution is TestFlight
  internal plus a sideload IPA; the published asset is unsigned.
- **"Stable" here is a channel label, not a quality claim.** GitHub will mark
  this Release as `latest` because the version carries no pre-release suffix,
  and that flag is the only thing separating it from `v0.0.1-dev.3`. Nothing in
  the build changed between them except the two fixes above.
- **No device matrix.** The rows below are empty because nobody has run them;
  they are not "passing".
- **No test result is claimed here.** The Swift test groups this stop adds are
  named below and their verdict belongs to the `Build and test (Xcode)` job,
  which had not run on this commit when this note was written. This note was
  produced on Linux, where the app cannot be compiled at all.
- **No signing executed end to end on a device at this stop**, and no off-device
  measurement of any kind — see
  [`../product/WHAT_DOES_NOT_EXIST.md`](../product/WHAT_DOES_NOT_EXIST.md).

### Testing

New unit tests: `SettingsSectionCatalogTests.testEveryRegisteredSectionIsReachableFromTheSettingsIndex`,
`testTheIndexOpensNothingThatIsNotRegistered` and `testEveryCategoryDescribesItself`;
`ShellSectionTabTests.testTheLandingPickerOffersOnlyTabsTheBarCanSelect`,
`testAFoldedSectionIsNotOfferedAsALandingTab`,
`testAStoredLandingTabWithNoSlotReadsAsTheTabLaunchOpens` and
`testARetiredLandingTabReadsAsLibrary`. One existing test was updated to the new
catalog: `VersionHistoryCatalogTests.testEntriesAreNewestFirst` now expects
`v0.0.1` first — it asserted the newest tag literally, which is the assertion
that makes an unrecorded stop fail. **Their results belong to CI** — the
`Build and test (Xcode)` job is the judge, and this note claims nothing about
them until it has run.

Host audits, run on the machine that produced this note (Linux, Python):

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | pass — 9 constructs, matching the baseline, every one justified |
| `Scripts/audit_accessibility.py` | pass on what a machine can check — 0 hard-coded colours outside `DesignTokens`, 0 controls under 44×44, 0 text nodes below the 0.75 comfort floor, 4 waived after review; VoiceOver, focus order and rendered contrast at every Dynamic Type size remain a human device pass |
| `Scripts/audit_regression_coverage.py` | pass — 9 behaviours executed in the app, 2 deferred to CI; every named test type exists |
| `Scripts/audit_navigation_stack.py` | pass — no pushed view opens its own `NavigationStack` |
| `Scripts/audit_identity_stability.py` | pass — every `Identifiable.id` in the app is stored, not minted per read |
| `python3 Scripts/audit_design_tokens.py --baseline Scripts/design_tokens_baseline.json --check` | pass — `✓ No category exceeds the design-token baseline.` (colour 0, radius 3, spacing 40, font 10, shadow 0, motion 1, haptics 0) |
| `bash Scripts/ci/architecture_guard.sh` | pass — 8 rules checked, no boundary violations |
| `python3 Scripts/release_train.py check` | pass — the tree declares `.horizon`, the stop this tag releases, with build 5 |
| `bash Scripts/ci/release_validate.sh 0.0.1` | pass — 0 warnings: train stage, `MARKETING_VERSION`, build number, the `[0.0.1]` changelog section and this notes file all agree |
| `python3 Scripts/update_readme.py --check` | pass — badge reads `0.0.1`, honest line `10 wired · 3 never` |
| `bash Scripts/ci/release_meta.sh` | pass, self-test green — prints `version 0.0.1 · tag v0.0.1 · channel stable · prerelease false` for this stop, which is what the header above and the GitHub Release flag come from |
| `python3 Scripts/ci/local_lint.py` | pass — `clean — no blocking findings` |
| `Scripts/ci/docs_check.sh` | pass — 0 errors; this file is linked from `CHANGELOG.md` and from `docs/releases/README.md`, so it is not an orphan |

Not run here, and not claimed: the Xcode build and the whole Swift test target.
This note was written on a Linux host with no Xcode and no Swift toolchain, so
the app was never compiled in the place that produced this file. The
`Build and test (Xcode)` job on the release commit is the only judge of that,
and it had not run when this note was written.

Device rows: **none.** The private matrix in
[`private-testing.md`](private-testing.md) (one iOS 17 device, one iOS 18
device, plus a simulator smoke) has not been run against the commit this tag
points at. `dev.3` published with that outstanding and named the matrix as the
gate for `v0.0.1`; this is the stop it was owed to, and it is still owed. No
row here is filled in from a simulator run or a wish.
