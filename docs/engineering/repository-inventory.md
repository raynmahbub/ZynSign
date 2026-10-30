# Repository inventory — initial redesign increment

Status: **Partially implemented**. This is a baseline and a targeted review, not a claim that all 1,009 Swift files, resources, and workflows have been individually audited.

## Baseline (2026-10-30)

- Branch `arena/a1891145-zynsign`, HEAD `78f3a3593f94b7a3c78cef50de1391a4e388bbdc`; initial worktree clean. Checkout is shallow/grafted; the only locally visible tag is `v0.1.0-alpha.3`. A read-only GitHub release/tag listing returned eight published tags from `v0.0.1-dev.1` through `v0.1.0-alpha.3`, all listed as prereleases. No tag or release was created.
- `Scripts/release_train.py status`: alpha.3, marketing version `0.1.0`, build `9`, next configured stop `v0.9.0-beta.1`. This is not proof of a published release or release readiness. Project deployment target is iOS 17.0. No `Package.swift`, `Package.resolved`, or workspace was found; Xcode project has `ZynSign` and `ZynSignTests` targets and synchronized source groups.
- 732 production Swift files: App 12, Application 173, Domain 261, Platform 102, Presentation 184; 276 Swift test files; one other Swift file outside those trees. Resources are under `ZynSign/Resources`; host tests and CI scripts under `Tests/Host` and `Scripts`. CI: build, quality, release, maintenance workflows in `.github/workflows`.
- Swift and Xcode were unavailable on this Linux host; no Xcode schemes, build, XCTest, simulator, or device verification could be run.

## Architecture and workflow map

`ZynSign/App/ZynSignApp.swift` and `CompositionRoot*.swift` compose the app. `Presentation` provides SwiftUI views and models; `Application` orchestrates workflows using domain models and platform ports; `Domain` contains value types and contracts; `Platform` supplies Apple and file/network adapters. `Scripts/ci/architecture_guard.sh` checks eight source boundary rules, but passing it does not establish absence of all cycles or direct platform coupling. See [architecture](../architecture/architecture.md).

- Import/inspection: `ImportHub`, `IPAPackageImport`, `ZipArchiveReader`, `ZipCentralDirectoryScanner`; archive policy in `ArchiveLimits`.
- Library: `ApplicationLibrary`, `ApplicationRecordStore`, artifact stores and presentation models.
- Signing: `SigningEngineCoordinator`, `SignApplicationPipeline`, `SigningOperationCenter`, verification and packaging services. Existing verification must not be equated with Apple device acceptance; see [signing pipeline](../architecture/application-signing-pipeline.md) and [external validation](../architecture/external-validation.md).
- Identity/profiles: `IdentityCenterService`, `IdentityStore`, `SecureIdentityStore`, profile inspection/verification; [identity documentation](../architecture/developer-identity-center.md).
- Store/download: `StoreRepository`, `StoreDownloadQueue`, `DownloadCenter`, platform URLSession adapters; [download architecture](../architecture/download-center.md).
- Devices/install/guest/tweaks: `DeviceBridgeService`, `InstallationWorkspace`, `GuestContainerHostService`, `TweakLibraryService`. Physical interoperability, guest isolation and JIT are not established by this inventory; consult [platform limits](../product/platform-limits.md) and [limitations](../product/WHAT_DOES_NOT_EXIST.md).

## Debt and target

The established layers and composition root should be retained, with dependencies and shared models consolidated incrementally only after call-site and migration review. See the [dead-code audit](dead-code-audit.md) and [refactoring report](architecture-refactoring-report.md). High-risk work includes untrusted ZIP parsing and extraction, signing/verification, Keychain and provisioning, network framing, guest loading, and lifecycle/persistence consistency. The entry-count extraction bug and ZIP64 arithmetic addressed in this increment are described in [security report](security-cleanup-report.md). Full source, resource, dependency, test and security reviews remain **Planned**; see [technical debt](technical-debt.md). No broad directory reorganization or release version change is justified by this partial baseline.
