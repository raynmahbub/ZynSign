# Feature Status — source inventory, not device evidence

This snapshot follows the source-controlled train at `v0.1.0-alpha.1` (`.alpha1`, marketing `0.1.0`, build `7`). Confirm the active value with `python3 Scripts/release_train.py status`; the source remains authoritative. The capability catalogue is at **Settings → Features** and is generated from `CoreFeature.allCases`, `ReleaseFeature.allCases`, and `UnsupportedFeature.allCases` in [`FeatureCatalog.swift`](../../ZynSign/Application/FeatureCatalog.swift). Tests assert that each registry is represented once and that staged statuses follow the train.

A source entry means code and a presentation surface exist; it does **not** mean the feature has passed XCTest, simulator, or physical-device verification. No Apple build or device reproduction has been performed in this checkout.

## Release-gated capabilities

`ReleaseTrain.current` is `.alpha1`. The current Release gate includes capabilities introduced at `.horizon` and `.alpha1`:

| Introduced stop | Features |
|---|---|
| `v0.0.1` (`.horizon`) | Certificate Studio, Provisioning Profile Manager, App Store, Downloads |
| `v0.1.0-alpha.1` (current) | Library Power Features |
| `v0.1.0-alpha.2` | Smart Sign, Signing Queue, Signing Presets |
| `v0.1.0-alpha.3` | Entitlements Studio, Developer Identity Center |
| `v0.9.0-beta.1` | Mission Control, Delivery Hand-off, Activity Journal |
| `v0.9.0-beta.2` | Installation Workspace, Performance Dashboard |
| `v0.9.0-beta.3` | Batch Signing |
| `v1.0.0-rc.2` | Smart Workspace |
| `v1.0.0` | Signing Health Score |
| `v3.0.0-nova.1` | Nova Assistant |

Features accumulate at later stops. Debug builds can expose staged code for development; the catalogue still labels Release availability from `ReleaseTrain`.

## Always-on and unsupported entries

`CoreFeature` registers always-on areas including package import, Library, Files and storage, bundle/binary/resource inspection, Compatibility Lab, Home, the feature index, tweak library, release feeds, revocation checks, app protection, encrypted backups, local privacy, preferences, and version history.

`UnsupportedFeature` records the limits the UI must disclose: in-app installation of arbitrary IPAs, device pairing/JIT/mux, and cloud sync/telemetry. Delivery hand-off materials are not an installer.

The shell gives the running stop direct root slots for Files, Library, Home, Store, Downloads, and Settings (gated destinations appear only when their release feature is open). The Features catalogue is a Settings workflow; Certificates and Profiles use one combined Home/Settings signing-material destination. `ShellTabBar` draws the custom bottom bar rather than using UIKit's five-item tab bar and its pushed *More* list. This does not replace the required runtime check on supported devices.

## Reported import and Settings issues

The `v0.0.1` tag already contains the source changes from ZynSign PR #77: the PKCS#12 identity protection rule accepts the Keychain's supported import protection classes and validates reported attributes, and post-picker presentations wait for dismissal. The tab shell was capped at UIKit's five-item limit there; the shell now draws its own bar and shows every destination instead (see above). That is source history, not proof the reported runtime paths worked for a user.

The post-picker waits no longer guess a duration. `PresentationSettle` asks the platform for its own state — no in-flight transition (`waitForIdle`), a sheet's own appearance report (`SheetPresentationReporter`) — and `presentAndConfirm` checks that something actually appeared, so the Import Hub's picker, the `.p12` password sheet, and the hub raised from Files each ask once more instead of being silently dropped on a device slower than the old 400 ms beat.

This checkout adds a bounded `.p12`/`.pfx` document reader that holds security-scoped access only during a coordinated read, moves file I/O off the main actor, and refuses empty or oversized inputs. Open In routes certificates and provisioning profiles directly into those same import paths; profile reads are coordinated with file providers. The IPA picker offers broad archive/document types (including `.ipa` and `.tipa` extensions) and delegates content validation to the import pipeline, whose reads remain coordinated when iCloud is still downloading. The importer and intake paths have XCTest coverage in the repository; the new Open In presentation flow still needs the private device check below, and Apple tests have not been run here.

The same class of crash was found and fixed while re-reading the presentation layer: **`BundleExplorerView`** (application detail → *View Bundle*, signing → *Explore IPA*) is pushed, and it builds `IPAExplorerScreen`, which opened its own `NavigationStack` (and a `NavigationSplitView` on iPad). That is a nested stack inside a pushed destination — a runtime crash the first time it is opened — and it was invisible to `audit_navigation_stack.py` because the pushed view was fine on its own and the view underneath it was not. `IPAExplorerScreen` now takes `embedsNavigationStack`, `BundleExplorerView` passes `false`, and the audit follows a pushed view's own constructions, requires a real `NavigationStack` use (the old substring test also matched the `embedsNavigationStack` flag), and honours the opt-out at the call site. Three regressions were injected to confirm the new rule catches them.

The **Settings crash** reported against the same build is not reproduced from source in this checkout, and this document does not claim it fixed. What the source shows: every destination `SettingsView` pushes either carries no navigation container or takes `embedsNavigationStack: false`; every `NavigationStack` under `Settings/` is inside a `#Preview`; `SettingsView` and its sections contain no `try!`, `as!`, force unwrap, `fatalError`, `precondition`, or unguarded index, and none was found by `audit_crash_surface.py` or `audit_navigation_stack.py`; `SettingsSectionCatalogTests` covers the catalog's reachability. One guard was added where a trap was possible: `SettingsView.moveCategories` bounds-checks the drop indices before `Array.move(fromOffsets:toOffset:)`, which traps on an out-of-range offset when a search narrows the visible rows. The shell's container also changed — Settings is rendered by the shell's own bar and container rather than by `UITabBarController` (`ShellTabBar`), so a crash originating in UIKit's tab-bar machinery, including its *More* overflow controller and its tab-item search wiring, can no longer be reached from the Settings tab. If the crash persists on a device, the report needs the failing tap and the exception or termination reason (`Settings` list, then which category, then which row); the private-testing matrix has the row for it.

## Verification status

- Host changelog tooling tests: **5 passed**.
- Documentation links, release-train consistency, release metadata self-test, architecture/dependency/navigation/regression source audits: **passed** in this checkout.
- Swift/XCTest build, simulator run, signed-host Keychain test, and physical-device test matrix: **not run**; `swift` and `xcodebuild` are unavailable in this environment.
- Until the private device matrix in [`private-testing.md`](../releases/private-testing.md) is completed, do not call certificate import, IPA/TIPA import, signing, Settings stability, or installation behavior device-verified.
