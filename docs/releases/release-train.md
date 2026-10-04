# Release Train

The release train in [`ZynSign/Application/ReleaseTrain.swift`](../../ZynSign/Application/ReleaseTrain.swift) owns the version sequence and feature exposure. It is the authority for `MARKETING_VERSION`, build-number progression, and the set of capabilities a Release build exposes. Use the scripts below rather than editing workflow versions by hand.

## Current source state

```sh
python3 Scripts/release_train.py status
```

At this checkout the current stop is **`v0.1.0-alpha.1`** (stage `.alpha1`, alpha channel; marketing version `0.1.0`, build `7`). The command is authoritative if this page and the source ever disagree. The current stop is not evidence that a release has been published or device-verified.

## Ordered stops

| Stop | Version | Newly exposed `ReleaseFeature`s |
|---|---|---|
| Dev 1 | `0.0.1-dev.1` | None — release-pipeline rehearsal |
| Dev 2 | `0.0.1-dev.2` | None |
| Dev 3 | `0.0.1-dev.3` | None |
| Horizon | `0.0.1` | Certificate Studio, Provisioning Profile Manager, App Store, Downloads |
| Patch 1 | `0.0.2-dev.1` | None — fixes-only follow-up |
| Alpha 1 | `0.1.0-alpha.1` | Library Power Features |
| Alpha 2 | `0.1.0-alpha.2` | Smart Sign, Signing Queue, Signing Presets |
| Alpha 3 | `0.1.0-alpha.3` | Entitlements Studio, Developer Identity Center |
| Beta 1 | `0.9.0-beta.1` | Mission Control, Delivery Hand-off, Activity Journal |
| Beta 2 | `0.9.0-beta.2` | Installation Workspace, Performance Dashboard |
| Beta 3 | `0.9.0-beta.3` | Batch Signing |
| Beta 4 | `0.9.0-beta.4` | None — fixes and compatibility |
| RC 1 | `1.0.0-rc.1` | None |
| RC 2 | `1.0.0-rc.2` | Smart Workspace |
| RC 3 | `1.0.0-rc.3` | None |
| Stable | `1.0.0` | Signing Health Score |
| Professional | `2.0.0` | None — depth and fixes |
| Nova preview | `3.0.0-nova.1` | Nova Assistant |
| Nova | `3.0.0` | Remaining Nova roadmap capabilities |

Each stop accumulates features from earlier stops. The stage definitions, prerequisites, marketing versions, and build numbers in `ReleaseTrain.swift` are authoritative; this table is a quick reference.

## What the app exposes

- **A tab per destination:** Files, Library, Home, Store, Downloads, Features, and Settings — every destination the stop exposes, each with its own slot. The shell draws its own bar (`ShellTabBar`) instead of using UIKit's, whose five-item ceiling folds the rest into a *More* list it pushes, and a pushed destination that owns a `NavigationStack` crashes at runtime. Earlier stops worked around that by hiding destinations, which is how the Store tab came to be missing; the shell now shows them instead. Certificates, Profiles, Presets, and the installation workspace remain workflows opened from Settings.
- **Features index:** available, staged, and unsupported capabilities are searchable and filterable. `CoreFeature.allCases`, `ReleaseFeature.allCases`, and `UnsupportedFeature.allCases` feed the catalogue. Adding a case includes it automatically; exhaustive metadata switches require its title, category, and explanation.
- **Release vs. Debug:** Release builds use the current train gate. Debug builds expose all release-gated features for development. The complete catalogue still labels the Release availability honestly.

## Commands

```sh
python3 Scripts/release_train.py status
python3 Scripts/release_train.py current --tag
python3 Scripts/release_train.py check --tag v0.1.0-alpha.1
python3 Scripts/release_train.py promote                 # next stop
python3 Scripts/release_train.py promote alpha2          # a named stop
```

`promote` advances the declared train stop and updates the Xcode marketing/build settings. Review its changes, run the checks, and commit the source before creating a tag. `check --tag` refuses a tag that is not the train's current stop or whose project settings disagree.

## Release and verification

The **Release** workflow (`.github/workflows/03-release.yml`) validates the train stop and quality gates, builds assets, generates categorized release notes, and publishes only on a non-dry run. It then opens or updates a changelog PR (or leaves the changelog staged on an automation branch when the repository does not let Actions open PRs); it does not write generated changelog edits directly to the default branch. See [release automation](release-automation.md).

Builds and passing CI are not device evidence. Follow the required physical-device and simulator checks in [private testing](private-testing.md), and keep unsupported platform behavior documented in [WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md). See [version strategy](version-strategy.md) for stage exit criteria and [Nova roadmap](../product/ROADMAP-v3.0-nova.md) for the post-1.0 plan.
