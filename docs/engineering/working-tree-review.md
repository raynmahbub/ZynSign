# Post-refactoring working-tree review

Status: **Incomplete review / manual validation required**. The branch is `arena/a1891145-zynsign`, HEAD `78f3a3593f94b7a3c78cef50de1391a4e388bbdc`. Work was preserved and remains uncommitted. The complete tracked diff was captured locally for review and file-level changes and subsystem-critical paths were inspected; this does not mean each changed line or every repository source file received a full audit. Untracked files are listed separately because `git diff` excludes them.

Reports: [device](device-transport-interoperability.md), [signing](signing-interoperability.md), [installation](installation-validation.md), [guest runtime](guest-runtime-validation.md), [CI readiness](github-actions-readiness.md), [technical debt](technical-debt.md).

## Local checks

- Python host unittest discovery with ResourceWarnings as errors: **165 passed in 15.455s**. Includes simulated host device tests, not Swift device transport.
- External validation self-test: **passed** synthetic parser/rules/report tests; not Apple-tool validation.
- Local lint, architecture guard (8 rules), crash audit (9 baselined constructs), docs check, `git diff --check`, and workflow shell syntax check (23 blocks) passed. The docs count is updated by the final command recorded in the conversation if different.
- Secret policy passed its local-tree patterns; Gitleaks absent, so no full-history Gitleaks scan. Heuristic dead-code scan reported 293 candidates; these are not verified dead code. Periphery unavailable.
- Swift compilation, XCTest, iOS simulator, Apple tools, legitimate IPA/identity matrix and physical device tests: **not run**; no Swift, Xcode, Apple SDK or devices here. No GitHub Actions run was started.

## Current increment

Pairing import now rejects unusable SystemBUID values, service-required TLS fails closed, transport scopes close on completion/error, and installation progress is bounded. A guest probe no longer asserts that a missing symbol uses `LC_MAIN`. Tests added for pairing and TLS refusal are unrun. These do not implement authenticated transport, complete signing, installation, or guest execution.

Suggested commit message (only if separately authorized): `fix: harden device and signing preparation boundaries`

## Complete file-level change summary

Tracked diff (`M` modified, `D` deleted):

```text
M	CHANGELOG.md
M	Tests/Host/test_device_bridge.py
M	Tests/Host/zynsim/device.py
M	Tests/ZynSignTests/ArchiveLimitsTests.swift
M	Tests/ZynSignTests/DownloadsResilienceTests.swift
M	Tests/ZynSignTests/FilePreferencesStoreTests.swift
M	Tests/ZynSignTests/InstallationDeliveryTests.swift
M	Tests/ZynSignTests/MachOSigningIntegrationTests.swift
M	Tests/ZynSignTests/SideloadingTests.swift
M	Tests/ZynSignTests/SigningOperationExecutorTests.swift
M	Tests/ZynSignTests/Support/ZipFixtureBuilder.swift
M	Tests/ZynSignTests/ZipArchiveReaderTests.swift
M	Tests/ZynSignTests/ZipEntryStreamExtractorTests.swift
M	Tests/ZynSignTests/ZynSigningPoliciesTests.swift
M	Tests/ZynSignTests/ZynTweaksAndInspectorsTests.swift
M	Tests/ZynSignTests/ZynUnifiedSideloadAndContainerTests.swift
M	Tests/ZynSignTests/ZynWorkspaceAndWebDAVTests.swift
M	ZynSign/App/CompositionRoot+Workspace.swift
M	ZynSign/Application/ApplicationEnvironment.swift
D	ZynSign/Application/BackgroundDownloadKeepAliveControlling.swift
M	ZynSign/Application/DeviceBridgeController.swift
M	ZynSign/Application/DeviceBridgeService.swift
M	ZynSign/Application/FileArchiveTools.swift
M	ZynSign/Application/GuestContainerHostService.swift
M	ZynSign/Application/InstallationDelivery.swift
M	ZynSign/Application/LANWebWorkspaceService.swift
M	ZynSign/Application/ProfileEntitlementDerivation.swift
M	ZynSign/Application/SideloadingCapability.swift
M	ZynSign/Application/SignMachO.swift
M	ZynSign/Application/SigningDiagnosticsService.swift
M	ZynSign/Application/SigningOperationExecutor.swift
M	ZynSign/Application/TweakStagingResolver.swift
M	ZynSign/Application/UserPreferences.swift
M	ZynSign/Domain/ArchiveLimits.swift
M	ZynSign/Domain/DebArchiveParser.swift
M	ZynSign/Domain/DeviceBridge/DeviceBridgeProtocols.swift
M	ZynSign/Domain/DeviceBridge/DevicePairingRecord.swift
M	ZynSign/Domain/LANWebWorkspace/WebDAVProtocol.swift
M	ZynSign/Domain/Sideloading/BinaryEntitlementMerger.swift
D	ZynSign/Platform/AVAudioBackgroundDownloadKeepAlive.swift
M	ZynSign/Platform/NetworkDeviceBridgeTransport.swift
M	ZynSign/Platform/NetworkLANWebWorkspaceServer.swift
M	ZynSign/Platform/PosixGuestRuntimeLoader.swift
M	ZynSign/Platform/URLSessionDownloadTransfer.swift
M	ZynSign/Platform/ZipArchiveReader.swift
M	ZynSign/Platform/ZipCentralDirectoryScanner.swift
M	ZynSign/Platform/ZipEntryStreamExtractor.swift
M	ZynSign/Presentation/DownloadsView.swift
M	ZynSign/Presentation/LANWebWorkspaceView.swift
M	ZynSign/Presentation/Settings/GeneralSettingsSection.swift
M	ZynSign/Presentation/SideloadingView.swift
M	ZynSign/Presentation/SigningView.swift
M	ZynSign/Presentation/TweakInspectorViews.swift
M	ZynSign/Presentation/UnifiedSigningHubView.swift
M	docs/architecture/download-center.md
M	docs/architecture/pairing-jit-mux-feasibility.md
M	docs/architecture/sideloading.md
M	docs/product/WHAT_DOES_NOT_EXIST.md
M	docs/releases/private-testing.md
```

Untracked files (not included in `git diff --stat`):

```text
Tests/Host/test_download_background_policy.py
Tests/ZynSignTests/DeviceTransportFramingTests.swift
ZynSign/Platform/BoundedDebTarDecoder.swift
docs/engineering/1.0-parity-plan.md
docs/engineering/architecture-refactoring-report.md
docs/engineering/competitor-feature-comparison.md
docs/engineering/dead-code-audit.md
docs/engineering/device-transport-interoperability.md
docs/engineering/github-actions-readiness.md
docs/engineering/guest-runtime-validation.md
docs/engineering/installation-validation.md
docs/engineering/regression-test-report.md
docs/engineering/repository-inventory.md
docs/engineering/security-cleanup-report.md
docs/engineering/signing-interoperability.md
docs/engineering/technical-debt.md
docs/engineering/working-tree-review.md
```
