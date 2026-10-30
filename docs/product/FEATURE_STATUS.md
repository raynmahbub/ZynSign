# Feature Status — source inventory, not device evidence

This snapshot follows the source-controlled train at `v0.1.0-alpha.3` (`.alpha3`, marketing `0.1.0`, build `9`). Confirm the active value with `python3 Scripts/release_train.py status`; the source remains authoritative. The capability catalogue is at **Settings → Features** and is generated from `CoreFeature.allCases`, `ReleaseFeature.allCases`, and `UnsupportedFeature.allCases` in [`FeatureCatalog.swift`](../../ZynSign/Application/FeatureCatalog.swift). Tests assert that each registry is represented once and that staged statuses follow the train.

A source entry means code and a presentation surface exist; it does **not** mean the feature has passed physical-device verification on hardware.

## Release-gated capabilities

`ReleaseTrain.current` is `.alpha3`. Ten staged `ReleaseFeature` flags are active in Release builds at `v0.1.0-alpha.3`, and eight remain staged for later stops along the train (`0.9.0-beta.1..4` → `1.0.0-rc.1..3` → `1.0.0` → `2.0.0` → `3.0.0-nova.1` → `3.0.0`):

| Introduced stop | Features |
|---|---|
| `v0.0.1` (`.horizon`) | Certificate Studio, Provisioning Profile Manager, App Store, Downloads |
| `v0.1.0-alpha.1` | Library Power Features |
| `v0.1.0-alpha.2` | Smart Sign, Signing Queue, Signing Presets |
| `v0.1.0-alpha.3` (current) | Entitlements Studio, Developer Identity Center |
| `v0.9.0-beta.1` | Mission Control, Delivery Hand-off, Activity Journal |
| `v0.9.0-beta.2` | Installation Workspace, Performance Dashboard |
| `v0.9.0-beta.4` | Export Center, Signing History |
| `v1.0.0-rc.2` | Smart Workspace |
| `v1.0.0` | Signing Health Score |
| `v3.0.0-nova.1` | Nova Assistant |

Features accumulate at later stops. Debug builds can expose staged code for development; the catalogue still labels Release availability from `ReleaseTrain`. A `Planned · <tag>` label names the stop that would expose the capability. Every entry in the table above now has a surface the gate can reveal: Batch Signing was retired from the train at `v0.9.0-beta.3` because the signing queue already ships that behaviour, and Signing Health Score (`v1.0.0`) renders on the Sign screen as `SigningHealthScoreCard`. `Scripts/audit_release_gating.py` enforces the rule — every `ReleaseFeature` must be referenced by the app's own source — and `Scripts/ci/release-surface-deferrals.txt` holds no entries.

## Always-on and unsupported entries

`CoreFeature` registers always-on areas including package import, Library, Files and storage, bundle/binary/resource inspection, Compatibility Lab, Home, the feature index, tweak library, release feeds, revocation checks, app protection, encrypted backups, local privacy, preferences, version history, and the sideloading report. Sideloading is core rather than release-gated because the screen *is* the explanation — each row names the requirement this build is missing (a pairing record, the local-tunnel entitlement, a bundled loader) — so a build that cannot install is exactly the build that has to show why. The package edits it previews are applied by the signing run, which is gated by `ReleaseFeature.smartSign`.

`UnsupportedFeature` records the limits the UI must disclose: in-app installation of arbitrary IPAs, device pairing/JIT/mux, and cloud sync/telemetry. Delivery hand-off materials are not an installer.

The shell gives the running stop at most five root slots — Home, Library, Store, Downloads, and Settings (`visibleTabs.count <= ShellSection.nativeTabBarItemLimit`). Files, the Features catalogue, and signing materials live inside Settings, and native `TabView` isolates each tab's `NavigationStack` without triggering UIKit's *More* overflow stack.

## Reported import, Settings, and smoothness fixes

- **Import reliability (`ZDocumentPicker` + `PickedDocumentStaging` + `Info.plist`):** All package, certificate, profile, tweak, and backup file pickers now use `ZDocumentPicker` (`UIDocumentPickerViewController(..., asCopy: true)`) with synchronous APFS temporary staging (`PickedDocumentStaging.stabilize`) instead of `.fileImporter` + `PresentationSettle.presentAndConfirm` polling, eliminating premature picker/sheet teardown and expired security-scoped URL failures. `Info.plist` sets `LSSupportsOpeningDocumentsInPlace = false` so Share Sheet / Open In hand-offs copy files into ZynSign's container, and `ImportHubView` automatically adds verified conflict-free packages to the Library by default.
- **Settings crash & stack isolation:** `RootView` uses native `TabView(selection:)` instead of mounting five simultaneous `NavigationStack`s and `UISearchController`s inside one `ZStack`. `SettingsView` removes un-sectioned `.onMove` + `editMode` collection diffing and presents `.searchable` / multi-destination workflows (`SigningMaterialsView`, `FeatureCatalogView`, `FilesView`, `PresetsView`, `SigningHistoryView`, `StoreSourcesView`, `DownloadsView`, `IPSWBrowserView`) inside dedicated `NavigationStack` sheets rather than pushing nested search controllers.
- **UI smoothness & Ksign-style clarity:** `ZGlass` replaces per-card backdrop blur and offscreen drop-shadow rasterization with crisp grouped-surface fills and hairline strokes, `SettingsView` adopts colored SF Symbol icon badges in native `.insetGrouped` sections, and `Library` / `Home` provide direct one-tap `+` IPA import and inline row `Sign` actions.

## Verification status

- Host Python & simulation suites (`Tests/Host/test_*.py`, `Scripts/sim/run_unified_suite.py`): **159 passed**.
- Documentation links, release-train consistency, release metadata self-test, architecture/dependency/navigation/crash-surface/accessibility/regression source audits: **passed** on this tree.
- macOS Xcode 26.3 CI (`01-build.yml` & `02-quality.yml`): builds `ZynSign` and `ZynSignTests`, runs Apple `codesign`/`openssl` external validation, and runs the iOS Simulator XCTest suite.
- Until the physical-device matrix in [`private-testing.md`](../releases/private-testing.md) is completed on hardware, do not call certificate import, live Apple ID 2FA provisioning, loopback-tunnel installation, Settings stability, or guest container execution device-verified.
