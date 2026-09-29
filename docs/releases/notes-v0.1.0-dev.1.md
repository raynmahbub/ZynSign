## [0.1.0-dev.1] — Development · the reset, and the pipeline that proves it

Market `0.1.0` build `1` (`CFBundleShortVersionString 0.1.0`,
`CFBundleVersion 1`), tag `v0.1.0-dev.1`. Release train `.dev1`: switches on
**no** staged feature. A Release build shows the core — Files, Import
(`ipa`/`tipa`), Library, Bundle Explorer, Home, Settings — and keeps all 19
staged features hidden until the stops that introduce them.

This is the first release on the permanent version structure. The three
pre-launch GitHub releases (`v0.1.0-dev`, `v0.1.1-dev`, `v0.2.0-dev`) and their
tags were deleted, and the train restarted here, so `latest` can never again
point at a pre-launch tag that sorts above `0.1.0`. A development stop's job is
not to expose features: it is to prove the release pipeline end to end against a
real tag — quality gate → build + tests → version-stamped assets → publish —
before any feature is offered publicly.

**The reset moved a pointer, not a plan.** Every feature is still compiled into
this binary; a Debug build exposes all 19, and `-ZynSignReleaseStage <stage>`
previews any later stop. Each stage after Development introduces exactly the
features it always did, so `promote` switches them back on in the planned order.

### Added

- **Development phase on the release train** *(the current stop)* — `.dev1`,
  `.dev2`, `.dev3` (`0.1.0-dev.1…3`) ahead of `.horizon`, each with an empty
  `introducedFeatures`. `Scripts/ci/release_meta.sh` already detected the
  `development` channel and asserted it in its self-test; the train had no stop
  for it, so the channel was unreachable. See
  `docs/releases/release-train.md`.
- **Five-workflow engineering system** *(no user-visible behaviour)* —
  `01-build.yml` (🔨 Build), `02-quality.yml` (🛡 Quality),
  `03-release.yml` (🚀 Release), `99-command-center.yml` (⚙ Command Center),
  and `release-drafter.yml`. Every gate from the previous twenty workflows is
  still enforced; none was dropped in the consolidation.
- **Crystal Flow** *(CI logs and summaries)* — `Scripts/ci/crystal.sh` gives
  every script one log language (phase banners, ✓ / • / ⚠ / ✗, GitHub
  annotations, summary cards). Sourced by 13 of the 16 `Scripts/ci/*.sh`;
  `select_simulator.sh` and `annotate_test_failures.sh` deliberately do not,
  because another process parses their stdout.
- **Version-stamped release assets** — `Scripts/ci/release_assets.sh` derives
  the whole set from the tag: `ZynSign-v{tag}-unsigned.ipa`,
  `ZynSign-v{tag}-SHA256.txt`, `BuildPassport-v{tag}.json`, `MANIFEST.md`,
  `ReleaseNotes.md`. No name and no value is hardcoded; the passport's
  toolchain, versions and feature counts are read at build time.
- **Release rehearsal** — Actions → 🚀 Release → `dry_run: true` runs every gate
  and builds the full asset set without publishing.

### Changed

- `ReleaseTrain.current` `.rc2` → `.dev1`
  (`ZynSign/Application/ReleaseTrain.swift`).
- `MARKETING_VERSION` `1.0.0` → `0.1.0`; `CURRENT_PROJECT_VERSION` `5` → `1`
  in all four build configurations. A new marketing version restarts the build
  number, which is the scope TestFlight's monotonic-build rule applies to.
- `README.md` version badge `1.0.0` → `0.1.0` and the release-train line to
  `v0.1.0-dev.1` (marketing `0.1.0`, build `1`), written by
  `Scripts/update_readme.py`.
- The pre-launch releases and their tags are gone from GitHub. Commit `58e604c`
  stays in history; nothing else was removed.

### Fixed

- **`ReleaseResetGuide.md` step 4 could not be executed.** It said to tag
  `v0.1.0-dev.1`, but `release_meta.sh` and `release_validate.sh` both refuse a
  version the train does not contain, and the train had no development stop. The
  guide also claimed the train is untouched by a reset; it now records the train
  change a reset actually requires.
- **`update_readme.py` left the README's marketing version and build number
  stale.** It rewrote the train tag but not the `(marketing X, build Y)`
  parenthetical beside it, and `--check` could not see the drift — so a reset
  would have published a README contradicting itself. All three values now come
  from the train and the Xcode project.
- **`update_readme.py` warned on every run** that the honest counts might not
  match, because it looked for `10 wired` while the badge stores `10%20wired`.
  A warning that always fires teaches everyone to ignore warnings.
- Docs that stated the current stop as `v1.0.0-rc.2` now state it as
  `v0.1.0-dev.1`, or derive it instead of naming it: `docs/releases/README.md`
  and `private-testing.md` no longer hardcode a version in the publish steps,
  and `03-release.yml`'s example takes its tag from
  `release_train.py current --tag`.
- `docs/releases/README.md` step 3 told the publisher to hand-run
  `gh release create`, which contradicts one-tag publishing: a hand-made release
  carries assets no gate produced. The tag push is now the whole manual step.

### Known limitations

Carried in `ReleaseBlockerRecord.registry`, shown in the Compatibility Lab, and
listed in `docs/product/WHAT_DOES_NOT_EXIST.md` (`10 wired · 3 never`):

- **In-app installation is unavailable.** *(Severity: blocking for that claim,
  accepted — no supported mechanism exists for an iOS/iPadOS app to install an
  arbitrary IPA. ZynSign builds the OTA manifest, `itms-services://` link and QR
  for a host you control, and says plainly that it never installs.)* See
  `docs/architecture/installation-compatibility.md`.
- **Pairing/JIT/Mux is never claimed.** *(Accepted — see
  `docs/architecture/pairing-jit-mux-feasibility.md`.)*
- **Off-device measurement is never claimed.** *(Accepted — the activity journal
  is on-device and never transmitted; no telemetry exists to measure.)*
- **External validation does not accept the pipeline's bundles.** Apple's
  desktop verifier accepts ZynSign's single-image signatures but rejects the
  pipeline's bundles, and the signature format fails the requirements Apple
  documents for iOS 15 and later. *(Open — see
  `docs/architecture/external-validation.md`.)*
- **A Release build of this stop exposes no staged feature.** *(By design, not a
  defect — the gate is the point of a development stop. Debug builds expose all
  of them, so no development or UI work is blocked.)*

### What this release deliberately does not claim

- **No feature was removed, deprecated, or lost.** They are hidden by the gate.
  A claim that the app "went back to a shell" would be as false as a claim that
  it is feature complete.
- **No device evidence.** Nothing in this note comes from a real iPhone or iPad.
  The private matrix in `docs/releases/private-testing.md` has not been run for
  this stop, and no device row below is filled in.
- **No test result.** The Swift changes in this release have not been executed
  where this note was written; there is no Swift toolchain on that host. The
  `Build and test (Xcode)` job is the judge, and this note claims nothing about
  its verdict until it has run.
- **Not an App Store submission, and not signed.** CI never signs; the IPA is
  `unsigned` by name. Distribution is sideload or TestFlight only.
- **No install, no "it worked on my device", no performance figure.** Nobody
  measured one for this tag.

### Testing

New unit tests: `testDevelopmentStagesProveThePipelineWithoutExposingFeatures`
(a development stop exposes nothing in Release, everything in Debug, and runs
into Horizon) and `testTheResetKeptTheWholeFeaturePlanIntact` (every feature is
still introduced exactly once, never by a development stop, and the stages after
Development are unchanged). Updated pins:
`testStagesFollowTheVersionStrategy`, `testMarketingVersionsAreNumericForApple`,
`testTagsCarryTheLeadingV`, `testNextWalksTheTrainAndStopsAtStable`,
`testStagesCanBeFoundByNameOrVersion`. **Their results belong to CI** — the
`Build and test (Xcode)` job is the judge, and this note claims nothing about
them until it has run.

Host audits, run on the Linux host that produced this note (the same scripts CI
runs — not a Mac, and not a simulator):

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | 9 constructs, every one justified; matches its baseline |
| `Scripts/audit_accessibility.py` | `accessibility.touchTargets` passed; 6 rows need review at reduced Dynamic Type, 4 waived after review. VoiceOver, focus order and rendered contrast are **not** settled here |
| `Scripts/audit_regression_coverage.py` | 9 behaviours executed in the app, 2 deferred to CI; every named test type exists in `Tests/ZynSignTests` |

Pipeline checks, run on the same host: `release_train.py check` and
`check --tag v0.1.0-dev.1` green; `release_meta.sh --self-test` green
(13 assertions) and `release_meta.sh 0.1.0-dev.1` resolving to channel
`development`, pre-release `true`; `release_validate.sh 0.1.0-dev.1` passing all
six checks; `release_assets.sh` producing all five assets with a verifying
SHA-256 and a passport recording `0 visible · 19 staged later`;
`update_readme.py --check` green.

Device rows: **none run.** No row is filled in from anything but a run.
