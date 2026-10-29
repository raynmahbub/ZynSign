# Release Train

The release train in [`ZynSign/Application/ReleaseTrain.swift`](../../ZynSign/Application/ReleaseTrain.swift) owns the version sequence and feature exposure. It is the authority for `MARKETING_VERSION`, build-number progression, and the set of capabilities a Release build exposes. Use the scripts below rather than editing workflow versions by hand.

## Current source state

```sh
python3 Scripts/release_train.py status
```

At this checkout the current stop is **`v3.0.0`** (stage `.nova`, marketing version `3.0.0`, build `12`) — the final stop on the release train, carrying all eighteen staged features plus the unified Free/Paid signing, loopback bridge, multi-app container, and workspace tooling. The command is authoritative if this page and the source ever disagree, and the current stop is not evidence that a release has been published or device-verified.

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
| Beta 3 | `0.9.0-beta.3` | None — fixes and compatibility |
| Beta 4 | `0.9.0-beta.4` | None — fixes and compatibility |
| RC 1 | `1.0.0-rc.1` | None |
| RC 2 | `1.0.0-rc.2` | Smart Workspace |
| RC 3 | `1.0.0-rc.3` | None |
| Stable | `1.0.0` | Signing Health Score |
| Professional | `2.0.0` | None — depth and fixes |
| Nova preview | `3.0.0-nova.1` | Nova Assistant |
| Nova | `3.0.0` | Remaining Nova roadmap capabilities |

Each stop accumulates features from earlier stops. The stage definitions, prerequisites, marketing versions, and build numbers in `ReleaseTrain.swift` are authoritative; this table is a quick reference.

A stop's row is a claim about what a build exposes, so it is only true where the
app holds a surface the gate can reveal. Both gaps that this table used to
schedule ahead of their surface have been settled:

- **Batch Signing (`v0.9.0-beta.3`) is retired.** It named a behaviour the
  signing queue already ships — sign a selection with one configuration, one
  job at a time — so the stop now carries no new gate and `ReleaseFeature` has
  no `batchSigning` case. `BatchSigningCoordinator` remains as the tested
  sequencer it always was, but nothing constructs it and no stop promises it;
  building a surface on it would create a second signing path beside
  `SigningOperationCenter`.
- **Signing Health Score (`v1.0.0`) has a surface.** The Sign screen renders
  `SigningHealthScoreCard` from `SigningHealthAssessment` for the identity,
  profile and bundle currently selected, so the `v1.0.0` row describes a card
  users will see rather than an invisible value.
- **The Smart Workspace (`v1.0.0-rc.2`) is Home at that stop.** `HomeView`
  renders `SmartWorkspaceView` from the composed `SmartWorkspaceService` when
  both the service and the gate agree, and its cards open the tabs that own the
  work. The classic dashboard's import doors stay; its counts, favourites, and
  recently imported summaries are carried by the widgets.

A reference is not the same thing as a reachable screen, and the export area
proved it: `ExportsPresentation`, `ExportCenter`, `ExportsCenterModel`, and the
whole detail screen existed, tested and composed, while no build ever installed
the port or built the list — "where did my signed package go?" had no answer.
[`Scripts/audit_presentation_ports.py`](../../Scripts/audit_presentation_ports.py)
now makes the shell's side of that promise mechanical: every `*Presentation`
value in `Presentation/` must be installed by `RootView`, and a deferral in
`Scripts/ci/presentation-port-deferrals.txt` fails once it has been repaid.

[`Scripts/ci/release-surface-deferrals.txt`](../../Scripts/ci/release-surface-deferrals.txt)
is therefore empty, and
[`Scripts/audit_release_gating.py`](../../Scripts/audit_release_gating.py)
enforces that it stays that way: every staged feature must be referenced by the
app's own source, and a deferral that has been repaid fails the build.
[`WHAT_DOES_NOT_EXIST.md`](../product/WHAT_DOES_NOT_EXIST.md) states both
decisions for users.

## What the app exposes

- **Root navigation:** the bar draws exactly five tabs — Home, Library, Store, Downloads, and Settings (`ShellSection.allTabs`, pinned by `ShellSectionTabTests`). The Files browser is one `Settings → Browse` row away, the searchable Features catalogue is under `Settings → Features`, and Certificates and Profiles share one `Home → Certificates & Profiles` entry and one `Settings → Signing` screen. Store and Downloads remain direct tabs when their release gates are open and are the only two of the five that a stage can hide. The shell draws its own glass bar (`ShellTabBar`) instead of UIKit's five-item bar, whose *More* list would push destinations into nested stacks; five is the product's count, never the ceiling's.
- **Features index:** available, staged, and unsupported capabilities are searchable and filterable from Settings. `CoreFeature.allCases`, `ReleaseFeature.allCases`, and `UnsupportedFeature.allCases` feed the catalogue. Adding a case includes it automatically; exhaustive metadata switches require its title, category, and explanation.
- **IPSW Browser:** Home and `Settings → Updates` provide device search, per-device firmware lists, signing status, and Apple-hosted download links. Status is reported by the public IPSW.me API and is not a restore guarantee.
- **Release vs. Debug:** Release builds use the current train gate. Debug builds expose all release-gated features for development. The complete catalogue still labels the Release availability honestly.

## Commands

```sh
python3 Scripts/release_train.py status
python3 Scripts/release_train.py current --tag
python3 Scripts/release_train.py check --tag v0.1.0-alpha.1
python3 Scripts/release_train.py promote                 # next stop
python3 Scripts/release_train.py promote stable          # a named stop
```

`promote` advances the declared train stop and updates the Xcode marketing/build settings. Review its changes, run the checks, and commit the source before creating a tag. `check --tag` refuses a tag that is not the train's current stop or whose project settings disagree.

## Release and verification

The **Release** workflow (`.github/workflows/03-release.yml`) validates the train stop and quality gates, builds assets, generates categorized release notes, and publishes only on a non-dry run. It then opens or updates a changelog PR (or leaves the changelog staged on an automation branch when the repository does not let Actions open PRs); it does not write generated changelog edits directly to the default branch. See [release automation](release-automation.md).

Builds and passing CI are not device evidence. Follow the required physical-device and simulator checks in [private testing](private-testing.md), and keep unsupported platform behavior documented in [WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md). See [version strategy](version-strategy.md) for stage exit criteria and [Nova roadmap](../product/ROADMAP-v3.0-nova.md) for the post-1.0 plan.
