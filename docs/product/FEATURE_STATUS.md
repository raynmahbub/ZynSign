# Feature Status — source inventory, not device evidence

This snapshot follows the source-controlled train at `v0.0.2-dev.1` (`.patch1`, marketing `0.0.2`, build `6`). Confirm the active value with `python3 Scripts/release_train.py status`; the source remains authoritative. The capability catalogue is in the app's **Features** tab and is generated from `CoreFeature.allCases`, `ReleaseFeature.allCases`, and `UnsupportedFeature.allCases` in [`FeatureCatalog.swift`](../../ZynSign/Application/FeatureCatalog.swift). Tests assert that each registry is represented once and that staged statuses follow the train.

A source entry means code and a presentation surface exist; it does **not** mean the feature has passed XCTest, simulator, or physical-device verification. No Apple build or device reproduction has been performed in this checkout.

## Release-gated capabilities

`ReleaseTrain.current` is `.patch1`. The current Release gate includes capabilities introduced at the earlier `.horizon` stop:

| Introduced stop | Features |
|---|---|
| `v0.0.1` (`.horizon`) | Certificate Studio, Provisioning Profile Manager, App Store, Downloads |
| `v0.1.0-alpha.1` | Library Power Features |
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

The Features tab reserves five native tab slots for Files, Library, Home, Features, and Settings. Store and Downloads are navigated from Features. This avoids UIKit's overflow `More` navigation stack; it does not replace the required runtime check on supported devices.

## Reported import and Settings issues

The `v0.0.1` tag already contains the source changes from ZynSign PR #77: the PKCS#12 identity protection rule accepts the Keychain's supported import protection classes and validates reported attributes, post-picker presentations wait for dismissal, and the tab shell is capped at UIKit's five-item limit. That is source history, not proof the reported runtime paths worked for a user.

This checkout adds a bounded `.p12`/`.pfx` document reader that holds security-scoped access only during a coordinated read, moves file I/O off the main actor, and refuses empty or oversized inputs. The importer guard prevents re-entry while a read or password sheet is pending. The IPA picker offers broad archive/document types (including `.ipa` and `.tipa` extensions) and still delegates content validation to the import pipeline. Those paths have XCTest coverage in the repository, but those Apple tests have not been run here.

## Verification status

- Host changelog tooling tests: **5 passed**.
- Documentation links, release-train consistency, release metadata self-test, architecture/dependency/navigation/regression source audits: **passed** in this checkout.
- Swift/XCTest build, simulator run, signed-host Keychain test, and physical-device test matrix: **not run**; `swift` and `xcodebuild` are unavailable in this environment.
- Until the private device matrix in [`private-testing.md`](../releases/private-testing.md) is completed, do not call certificate import, IPA/TIPA import, signing, Settings stability, or installation behavior device-verified.
