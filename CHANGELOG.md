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
