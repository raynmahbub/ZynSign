<div align="center">

<img src="Assets/Brand/Motion/hero.gif" alt="ZynSign — on-device iOS signing workspace" width="720">

**Import, inspect, and sign iOS app packages on-device, then prepare a delivery hand-off.**

[Build & tests](.github/workflows/01-build.yml) · [Quick start](docs/development/QuickStart.md) · [Release train](docs/releases/version-strategy.md) · [Security](SECURITY.md)

</div>

## Product areas

- **Import & library:** bounded `.ipa`, `.tipa`, and archive intake; persistent app library, files, collections, search, and storage controls.
- **Identity & signing:** Keychain-backed `.p12`/`.pfx` identities, provisioning profiles, compatibility checks, signing pipeline, queue, and presets as each release-train stage exposes them.
- **Inspection:** read-only bundle, binary, signature, resource, entitlement, and compatibility views.
- **Discovery & delivery:** repository feeds, validated downloads, update review, a searchable IPSW firmware browser with reported signing status, and OTA hand-off materials for an IPA you host. ZynSign does not install apps or host packages.
- **Workspace & care:** Home, accessibility-aware preferences, local diagnostics, backups, and privacy controls.

The main screen draws exactly five tabs — Home, Library, Store, Downloads, and Settings — in the **Storefront** shell: the storefront look that ships as the default theme, rendered in liquid glass across cards, bars, chrome, and toasts (iOS 26 uses the platform's own glass effect; earlier systems get ZynSign's material treatment). **Settings → Appearance → Liquid Glass** turns the glass off without touching anything else, and the previous themes stay selectable. Files, the Features catalogue, and signing materials live inside Settings.

The **Features** catalogue lives at **Settings → Features** and shows what is available, staged for a later train stop, or unsupported. [`CoreFeature`, `ReleaseFeature`, and `UnsupportedFeature`](ZynSign/Application/FeatureCatalog.swift) registries feed the catalogue through `allCases`; adding a case adds it automatically, while exhaustive metadata keeps its title, category, and explanation explicit. **Home → Certificates & Profiles** opens one combined signing-material area. The IPSW Browser is available from Home and **Settings → Updates**.

## Platform boundaries

- iOS 17 or later; iPhone and iPad.
- Xcode 16+ to build. The app uses Swift and SwiftUI and has no third-party runtime dependency.
- Signing and inspection run locally. Private keys stay in Keychain; no cloud sync or analytics service is composed.
- ZynSign prepares a signed package and delivery instructions; it does **not** install arbitrary IPAs on stock iOS. See [unsupported capabilities](docs/product/WHAT_DOES_NOT_EXIST.md).

## Build and run

```sh
git clone https://github.com/raynmahbub/ZynSign.git
cd ZynSign
open ZynSign.xcodeproj
# Choose an iOS 17+ simulator or device, then Product → Run / Product → Test
```

A typical workflow is: import an `.ipa` → add a certificate and provisioning profile → review compatibility → sign → share the output or prepare an OTA hand-off. See the [Quick Start](docs/development/QuickStart.md).

## Engineering

The app is organized into **Presentation → Application → Domain ← Platform**, composed by `ZynSign/App/CompositionRoot.swift`. See the [architecture guide](docs/architecture/architecture.md) and [signing pipeline](docs/architecture/application-signing-pipeline.md).

```sh
python3 Scripts/release_train.py status
python3 -m unittest discover -s Tests/Host -p 'test_*.py' -v
Scripts/ci/docs_check.sh
```

CI builds and tests on macOS and runs repository audits. Source-level checks and CI are not device evidence: IPA import, certificate import, signing, and OTA hand-off still require the documented [private test gate](docs/releases/private-testing.md).

## Releases

Versioning and feature exposure follow the source-controlled [release train](docs/releases/release-train.md). Release automation builds categorized notes from Conventional Commits, publishes the assets, then opens a reviewable changelog PR; see [release automation](docs/releases/release-automation.md).

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report vulnerabilities privately using [SECURITY.md](SECURITY.md), not a public issue.

## License

[MIT](LICENSE).
