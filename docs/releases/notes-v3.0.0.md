## [3.0.0] — Nova complete: unified Free & Paid signing, loopback installer, multi-app container, and workspace studio

Market `3.0.0` build `12` (`CFBundleShortVersionString 3.0.0`,
`CFBundleVersion 12`), tag `v3.0.0`. Release train `.nova`.

`v3.0.0` is the final stop on ZynSign's release train (`18 staged · 18 on · 0 ahead · 3 never`). Building on `v3.0.0-nova.1`, this release unifies Free Apple ID provisioning, wire-free loopback device installation, the zero-slot multi-app guest container, Paid `.p12` / `.zcert` certificate management, `.deb` / Mach-O tweak engineering, LAN WebDAV workspace sharing, and built-in Plist/Hex/Text editors into one zero-dependency native Swift application, while resolving all Xcode 26.3 SDK build issues and removing retired scaffolding.

### Added

- **Unified Signing & Provisioning Hub** — `UnifiedSigningHubView` and `AppleAccountProvisioningService` combine Free Apple ID SRP-6a + 2FA authentication, automatic ECDSA/RSA CSR generation, developer certificate issuance, UDID registration, Wildcard App ID + App Group creation, and 7-day provisioning profile renewal with Paid `.p12`/`.pfx` certificates, portable `.zcert` (`ZynCertificateBundle`) archives, bounded `.p12` passphrase recovery, bundled `signing-assets/` discovery, and encrypted DNS (`.mobileconfig`) revocation-shield profiles.

- **Wire-Free Loopback Device Bridge & Zero-Slot Multi-App Container** — `PosixLockdowndTransport` and `DeviceBridgeController` stream signed IPAs directly over local `lockdownd` (`com.apple.afc` + `com.apple.mobile.installation_proxy`) when paired over a local tunnel, while `GuestContainerHostService`, `AdHocMachOSigner`, and `PosixGuestRuntimeLoader` ad-hoc sign (`CodeDirectory v0x20400` SHA-256 + DER slot 7), sandbox, and host unlimited guest apps without consuming Apple's 3-app free-account slot ceiling.

- **Tweak Studio, `.deb` Extractor, & Compatibility Patchers** — Pure-Swift Debian `2.0` (`ar` + `gzip`/`xz`/`lzma` tar) extraction (`DebArchiveParser`), Mach-O load-command and `@rpath` inspection, per-dylib injection toggles, framework/extension stripper, structured `Info.plist` & Entitlements editors, Liquid Glass SDK `26.0` compatibility patching, and PPQ bundle-identifier protection.

- **LAN WebDAV Server, Portable Workspace, & File Editors** — Browser drag-and-drop plus RFC 4918 WebDAV mounting (`NetworkLANWebWorkspaceServer`), `Documents/ZynSignPortable/` bidirectional sync (`PortableWorkspaceSyncService`), in-app Property List / Hex / Text editors (`FileEditorsView`), web IPA/repo link extraction (`WebLinkExtractorSheet`), and optional silent-audio background download keep-alive.

- **DER Entitlements Decoder, Two-Week Refresh Calendar, & Opt-In Refresh Reminders** — Strict slot-7 DER claim decoding (`DEREntitlementsDecoder`), a 14-day lease refresh strip with plain-text schedule export in Sideload Studio, and opt-in local refresh notifications.

### Fixed & Cleaned Up

- **Xcode 26.3 Compilation Fixes** — Added `LocalTransferHTTP.Method.isReadOnly`, updated `SelfUpdateChecker` to call `AppVersionComparison.isUpdate(_:over:)`, switched `TweakStagingResolver` directory bundle detection to `TweakKind.infer(fromFileName:).isDirectoryBundle`, replaced non-existent `URLResourceKey.posixPermissionsKey` lookups in `FileArchiveTools` with `URLResourceKey.isExecutableKey`, and replaced invalid `UTType.pkcs12` references in `CertificateToolsSheets` with explicit PKCS#12 UTTypes (`p12`, `pfx`, `com.rsa.pkcs-12`, `com.microsoft.pkcs12`).
- **AppIntents & Dead-Code Cleanup** — Routed `SyncPortableWorkspaceIntent` through the active `ApplicationEnvironment` via `RootView` instead of instantiating a second environment, removed obsolete `PlaceholderFeatureView.swift` and `Scripts/split_composition_root.py`, and pruned unreferenced scaffolding factories and unused UI/domain helpers.

### Limits — unchanged, and deliberately so

- **Platform boundaries stay explicit.** Stock iOS has no public API to install an arbitrary IPA without either an entitled pairing/tunnel transport or user-confirmed OTA hand-off. `UnsupportedFeature` keeps the three recorded platform limits (`3 never`) documented in `docs/product/WHAT_DOES_NOT_EXIST.md`.
- **No cloud sync and no off-device telemetry.** `AnalyticsPolicy.isEnabled` remains `false`, the endpoint is `nil`, and zero events leave the device.

### Verification

- `Scripts/ci/version_claims.py`: `v3.0.0 · build 12 · 18 of 18 staged features · 3 never`
- `Scripts/ci/release_validate.sh 3.0.0` & `Scripts/ci/release_meta.sh --self-test`
- `Scripts/ci/architecture_guard.sh`, `Scripts/ci/docs_check.sh`, `Scripts/audit_accessibility.py --strict`, `Scripts/audit_design_tokens.py --check`, `Scripts/sim/run_unified_suite.py`
