## [3.0.0] — nova · 2026-10-30

Market `3.0.0` build `12` (`CFBundleShortVersionString 3.0.0`,
`CFBundleVersion 12`), tag `v3.0.0`. Release train `.nova` (`channel: stable`, `prerelease: false`).

`v3.0.0` completes the Nova release train (`18 staged · 18 on · 0 ahead · 3 never`). Building on `v3.0.0-nova.1`, this release brings unified Free Apple ID and Paid Certificate signing, wire-free loopback device installation, the zero-slot Multi-App Host Container, `.deb` and Mach-O tweak tooling, foreground LAN/WebDAV transfer workspaces, and built-in Plist/Hex/Text editors into one zero-dependency native Swift application while preserving ZynSign's four-layer architecture and explicit platform-limit disclosures.

### Added

- **Unified Signing & Provisioning Hub (`UnifiedSigningHubView`, `AppleAccountProvisioningService`)** — Combines Free Apple ID GSA authentication (`URLSessionAppleDeveloperPortalClient` + `AnisetteHeaderBundle` + 2FA verification), automatic Keychain RSA-2048 CSR generation (`KeychainCSRIdentityProvisioner` + `PKCS10CertificateRequestBuilder`), developer certificate issuance, device UDID registration, team-scoped App ID + App Group provisioning (`PersonalTeamBundleIDPlanner`), and 7-day `.mobileprovision` renewal with Paid `.p12`/`.pfx` identities, portable `.zcert` archives (`ZynCertificateBundle`, `CertificateBundleAssistant`), bounded `.p12` passphrase recovery, bundled `signing-assets/` discovery (`BundledSigningAssetsDiscovery`), and encrypted DNS (`.mobileconfig`) revocation-shield generation (`DNSRevocationShieldProfile`).
- **Wire-Free Loopback Device Bridge (`DeviceBridgeController`, `NetworkDeviceBridgeTransport`)** — Imports and stores pairing records in Keychain (`KeychainPairingRecordStore`) and streams signed IPAs over loopback `lockdownd` (`USBMuxProtocol`, `LockdowndProtocol`, `AFCProtocol`, `InstallationProxyProtocol`) when paired over a local tunnel.
- **Zero-Slot Multi-App Host Container (`GuestContainerHostService`, `GuestMachOPatcher`, `AdHocMachOSigner`)** — Extracts `arm64` slices from universal binaries, converts `MH_EXECUTE` (`MH_PIE`) binaries into `dlopen`-loadable `MH_DYLIB` images with neutralized `__PAGEZERO`, signs guest bundles with `CS_ADHOC` (`CodeDirectory` `v0x20200` SHA-256 + XML slot 5), isolates multi-profile sandbox data slots (`GuestDataSlot`), exports/restores slot data `.zip` archives, restores standalone `.ipa` packages, and builds Home-Screen WebClip `.mobileconfig` launchers (`GuestWebClipProfileBuilder`) without consuming Apple's 3-app free-account slot ceiling.
- **Tweak Studio, `.deb` Extractor & Compatibility Patchers (`DebArchiveParser`, `TweakStagingResolver`, `MachOBinaryPatcher`, `PPQProtectionPolicy`, `BinaryEntitlementMerger`)** — Pure-Swift Debian `2.0` (`ar` + `gzip`/`xz`/`lzma` tar) extraction, Mach-O load-command and `@rpath` inspection (`TweakMachOAnalyzer`, `TweakInspectorViews`), wildcard/exact auto-inject rules (`TweakAutoInjectRule`, `FileTweakAutoInjectStore`), `CydiaSubstrate` → `ElleKit` `@rpath` rewriting, legacy `arm64e` ABI normalization, iOS 26 `LC_BUILD_VERSION` SDK Liquid Glass patching, PPQ bundle-identifier protection, structured `Info.plist` & Entitlements editors (`SigningPlistEditorsView`), and sign-free package modification (`PackageModificationService`).
- **Foreground LAN Transfer, WebDAV Server, Portable Sync & File Editors** — Token-gated single-route upload listener (`LocalTransferService`, `NetworkLocalTransferServer`), foreground browser drag-and-drop plus RFC 4918 WebDAV workspace (`LANWebWorkspaceService`, `NetworkLANWebWorkspaceServer`, `WebDAVProtocol`), bidirectional `Documents/ZynSignPortable/` sync (`PortableWorkspaceSyncService`), Property List / Hex / UTF-8 Text editors (`FileEditorsView`, `PlistDocumentCodec`, `HexDumpFormatter`), HTML download-link extraction (`DownloadLinkExtractor`, `WebLinkExtractorSheet`), Base64/AES-128-CBC/compact repository feed normalization (`EncodedCatalogPayloadDecoder`), URL scheme + App Shortcuts routing (`IncomingURLRouter`, `ZynSignShortcuts`), and optional silent-audio foreground download keep-alive (`AVAudioBackgroundDownloadKeepAlive`).
- **DER Entitlements Decoder, Refresh Calendar & Opt-In Reminders** — Strict slot-7 DER claim decoding (`DEREntitlementsDecoder`), a 14-day Sideload Studio refresh calendar with plain-text schedule export, and opt-in local refresh notifications.

### Changed

- **Release train promoted to `.nova` (`v3.0.0`, build `12`).** `ReleaseTrain.current` advances from `.nova1` (`v3.0.0-nova.1`, build `11`) to `.nova` (`v3.0.0`, build `12`), completing all 18 staged features on the train and publishing on the `stable` channel (`prerelease: false`).
- **Post-edit signing discovery & profile-less modification.** `SignApplicationPipeline` and `VerifySignedApplication` re-run nested-code discovery (`DirectoryNestedCodeInspectionSource`) after sideload package edits and honor `removesProvisioningProfile` and rewritten bundle identifiers end to end.
- **Measured process entitlements.** `ProcessEntitlements` inspects the running binary's own embedded signature at launch (`SecTaskEntitlementReader`) so `Settings → Sideloading` distinguishes *granted*, *absent*, and *not established* rather than assuming absence.

### Fixed

- **Xcode 26.3 & Swift 6 strict-concurrency alignment.** Resolved all Xcode 26.3 (`17C529`, iOS 26.2 SDK) build and actor-isolation issues across `Domain`, `Application`, `Platform`, and `Presentation`, including `@MainActor` `ObservableObject` `nonisolated init` backing-storage initialization, `Identifiable` conformances, Domain wrapper conversions, `RootView` tab/sheet routing, `LocalTransferHTTP.Method.isReadOnly`, `SelfUpdateChecker`, `TweakStagingResolver`, `FileArchiveTools`, and explicit PKCS#12 `UTType` identifiers.
- **Sideload draft defaults, compact catalog normalization & CI diagnostics.** Aligned `SideloadOptionsDraft.allowsTweakCollisionSuffixing` with `SideloadSigningOptions.none`, added compact `bundleID` → `bundleIdentifier` normalization in `EncodedCatalogPayloadDecoder`, fixed receipt-order assertion in `LocalTransferTests`, added Xcode 26.3 `xcresulttool` JSON fallback in `Scripts/ci/annotate_test_failures.sh`, moved `Lint and format` to `ubuntu-24.04`, and pruned 775 lines of retired scaffolding.

### Known limitations

- **Wire-free loopback installation requires pairing + local tunnel.** Streaming an `.ipa` to `com.apple.mobile.installation_proxy` on non-jailbroken iOS requires an imported pairing record and an active local loopback tunnel (`127.0.0.1` / `10.7.0.1`). Without both, `DeviceBridgeController` reports the missing requirement and refuses to start a session.
- **Free Apple ID Personal Team constraints.** Free Apple ID provisioning requires a user-supplied Anisette v3 header endpoint and remains subject to Apple's Personal Team rules: 7-day profile validity, 3 active direct-installed apps per device, up to 10 App IDs per rolling 7 days, and personal-team entitlement restrictions (for example no Push Notifications).
- **Host Container guest compatibility.** `GuestContainerHostService` stages decrypted 64-bit `arm64` `MH_PIE` executables in-process, strips App Extensions / Watch apps that require SpringBoard registration, and runs JIT-less guests by default. FairPlay-encrypted App Store binaries (`cryptid != 0`) are refused with a typed error.
- **Foreground network listeners.** Both `LocalTransferService` and `LANWebWorkspaceService` run only while ZynSign is open in the foreground; neither registers a background daemon.

### What this release deliberately does not claim

- **No silent or entitlement-free SpringBoard installation.** ZynSign does not claim to install arbitrary IPAs onto iOS without either user-configured loopback pairing + tunnel (`DeviceBridgeService`) or user-initiated OTA/MDM/host delivery (`InstallationCapabilityAssessment.deliveryMechanismAvailable == false`).
- **No JIT debugger attachment, private framework linkage, or bundled OpenSSL.** `PairingCapability` keeps `jit` at `.notComposed`; no `MobileDevice` private framework, `usbmuxd` Unix socket, or OpenSSL library is linked into the application binary (`OpenSSL` runs only in host CI validation).
- **No slot-7 DER entitlement emission in signed output.** `DEREntitlementsDecoder` reads slot-7 DER claims for inspection, while `SignApplicationPipeline` continues to refuse `emitDEREntitlements` (`unsupportedInput`) and `AdHocMachOSigner` emits `CodeDirectory v0x20200` + XML slot 5.
- **No cloud sync, remote signing server, or off-device telemetry.** `AnalyticsPolicy.isEnabled` remains `false` (`endpoint == nil`, `0` events transmitted). Apple Developer Portal traffic occurs only on-device when the user explicitly signs in.

### Testing

| Test file | Cases | Covers |
|---|---:|---|
| `Tests/ZynSignTests/LocalTransferTests.swift` | 34 | Bounded HTTP/1.1 head parsing, constant-time token auth, upload size/extension limits, collision-safe storage, and session expiry |
| `Tests/ZynSignTests/ZynUnifiedSideloadAndContainerTests.swift` | 5 | Universal `arm64` thinning, `MH_EXECUTE` → `MH_DYLIB` + `__PAGEZERO` patching, `CS_ADHOC` signing, multi-slot container staging/backup/standalone `.ipa` export, strategy advisor, WebClip `.mobileconfig`, PKCS#10 CSR, Anisette bundle, and pairing import |
| `Tests/ZynSignTests/ZynSigningPoliciesTests.swift` | 4 | PPQ stealth/suffix bundle-ID protection, legacy `arm64e` + SDK 26 + install-name binary patching, and authorized binary entitlement merging with Keychain isolation |
| `Tests/ZynSignTests/ZynSourcesAndCertificatesTests.swift` | 4 | `.zcert` JSON/Plist round-trip, `.p12` passphrase candidate generation, Base64/compact catalog decoding, encrypted DNS `.mobileconfig`, and HTML IPA/OTA link extraction |
| `Tests/ZynSignTests/ZynTweaksAndInspectorsTests.swift` | 3 | `TweakMachOAnalyzer` `CydiaSubstrate` detection, exact/wildcard auto-inject rules, and pure-Swift Debian `2.0` (`ar` + `ustar`) unpacking |
| `Tests/ZynSignTests/ZynWorkspaceAndWebDAVTests.swift` | 3 | RFC 4918 WebDAV multistatus XML + path traversal sanitization, `PlistDocumentCodec` + `HexDumpFormatter` round-trips, and `zynsign://` / `zyn://` URL routing |
| `Tests/Host/test_*.py` | 159 | Host simulation suite (`zynsim`), Mach-O/nested/ZIP signing vectors, changelog generator, and XCTest evidence verification |

Host audits (measured on this tree):

- Crash surface (`Scripts/audit_crash_surface.py`): `9 construct(s), every one justified`
- Accessibility (`Scripts/audit_accessibility.py --strict`): `0 hard-coded colours, 0 controls below 44×44pt, 4 waived, 0 review`
- Regression catalogue (`Scripts/audit_regression_coverage.py`): `11 behaviours · 9 executed in-app · 2 deferred to CI · every named test type exists`

Device rows: CI validates host audits, Apple `codesign`/`openssl` external tooling, and the `3,237`-case iOS Simulator XCTest suite on Xcode 26.3 (`macos-15`, iPhone 16 Pro / iOS 26.2). Physical-device verification rows in [`docs/releases/private-testing.md`](private-testing.md) — hardware Keychain import, live Apple ID 2FA provisioning against an Anisette endpoint, loopback-tunnel pairing installation, and on-device guest container execution — are not established by CI and remain gated on physical iOS hardware testing.
