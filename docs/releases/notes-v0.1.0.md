## [0.1.0] - 2026-09-25

First public development build — **Horizon** — on `arena/01a0d570-zynsign`.
Market `0.1.0` build `4` (`CFBundleShortVersionString 0.1.0`, `CFBundleVersion 4`),
tag `v0.1.0`. The same binary is tested privately (TestFlight internal / ad-hoc IPA)
and then published — no rebuild between private and public.

This release completes `docs/product/WHAT_DOES_NOT_EXIST.md`: **9 wired, 3 never** —
in-app installation, Pairing/JIT/Mux, and off-device analytics stay claimed-never,
while the installation delivery hand-off and the local activity journal are wired.
Signed output is `Documents/Signed/*_signed.ipa` with Share and **Deliver…**.

### Added

- **Certificate Studio + Export** — Import `.p12`/`.pfx` (≤ 10 MiB) via `SecPKCS12Import`,
  store in `SecureIdentityStore` (`WhenUnlockedThisDeviceOnly`, non-extractable, duplicate
  SHA-256 rejected). `Settings → Certificates` shows subject / issuer / serial / SHA-256 /
  validity / key info with `ZStatusBadge` and exports *public* JSON only
  (`CertificateExportService` → `tmp/ZynSign-Export/*.json` via `UIActivityViewController`).
  Private key never leaves the Keychain.

- **Smart Sign (9 stages)** — `Library → Sign` / `Detail → Sign` runs
  `integrity → profile → discovery → extraction → nestedSigning → resourceSealing → mainExecutable → packaging → verification`
  with `ZProgressRing` + `ZSigningStatusMachine`. Entitlements are derived from the
  `.mobileprovision` (CMS → plist → `CodeSigningEntitlements`, unknown keys preserved,
  8-key preview) with fallback to empty only when derivation fails. `tipa` accepted as alias for `ipa`.

- **DER entitlements (iOS 15+)** — Toggle `0x20200` (slot 5) / `0x20400` (slot 5+7) in
  `SigningView`. `DEREntitlementsSerializer` produces deterministic `DER SET` (`0xFADE7172`)
  and `CodeDirectoryVersion.v20400` (52-byte header, slot 7 gated). Pipeline wired via
  `SignApplicationOptions.emitDEREntitlements` (default `false`).

- **Live Activities** — `LiveActivityService` (`ActivityKit` on iOS 16.1+, in-app `ZStatusBadge` fallback)
  mirrors `ZynSignLiveActivityState` (stage / progress / detail) during signing
  (`start → update 0.2/0.9 → end`) in `SigningView`.

- **Repository Health** — `App Store` sources show `Fast < 800 ms` / `Slow < 3 s` / `Offline`
  (`RepositoryHealthProbe` 3 s, `reloadIgnoringLocalCacheData`, HTTP 2xx + JSON validation).
  Row displays `ZStatusBadge` + latency and `Check Health` on demand; `refresh()` maps latency to health.

- **Background Downloads** — `Downloads` uses `BackgroundURLSession` (`com.zynsign.downloads`,
  60 s request / 600 s resource, `waitsForConnectivity`, `sessionSendsLaunchEvents`) with
  resume data, retry × 3, SHA-256 verification, `Pause` / `Resume` / `Cancel`, and progress.
  Survives backgrounding (foreground on Simulator).

- **Mission Control** — `Home → Refresh Everything` (`MissionControlService`) runs
  `refresh repositories → library re-read → cache cleanup` (`tmp` 24 h + `Downloads` 500 MiB / 7 d)
  with report (`Completed` / `Unavailable` + counts + duration ms). Re-sign is policy-checked, never auto-triggered.

- **Honest capabilities (explicit)** — `InstallationCapability` (`deliveryMechanismAvailable == false`,
  `Settings → Installation` `Unavailable` with the hand-off described), `PairingCapability`
  (`allUnavailable` + feasibility notes, `Settings → Pairing` `Never`), `AnalyticsPolicy`
  (`isEnabled == false`, `0 events sent`, 6 guarantees incl. `localJournalOnly`).
  See `docs/product/WHAT_DOES_NOT_EXIST.md` for code references.

- **Installation delivery hand-off** — `Sign → Deliver…` opens `InstallationDeliveryView`
  (`Application/InstallationDelivery.swift`): enter the HTTPS address where you will host the
  signed IPA and ZynSign builds Apple's `itms-services` `manifest.plist`, a percent-encoded
  install link, an on-device QR code (Core Image `CIQRCodeGenerator`,
  `Platform/DeliveryQRCodeRenderer.swift`), and step guides for the three operator channels —
  OTA hosting, MDM, and host tooling. HTTPS-only by design (`file://`/`http://` refused with a
  typed `InstallationDeliveryError`). ZynSign never uploads, hosts, probes a server, or learns
  an installation outcome; `deliveryMechanismAvailable` stays `false` on every path.

- **Local activity journal (on-device analytics)** — `LocalAnalyticsEvent` (category + fixed
  slug + outcome + time — no bundle identifiers, paths, or device/user identifiers) recorded
  by `FileLocalAnalyticsJournal` (JSONL in the app container, capacity 500, atomic writes,
  damaged lines skipped) behind the `LocalAnalyticsRecording` port
  (`Application/LocalAnalyticsJournal.swift`), composed in `CompositionRoot` and gated by the
  `AnalyticsPolicy.journalDefaultsKey` preference. `Settings → Analytics` shows the toggle,
  live counts, recent activity, one-tap Clear, and Export. Wired call sites: import, sign,
  certificate import, download outcomes, delivery manifest generation. Events never leave
  the device.

- **Pairing/JIT/Mux feasibility record** — `docs/architecture/pairing-jit-mux-feasibility.md`
  records the rejected-never decision: the private surface each capability needs
  (MobileDevice/lockdown entitlements, `get-task-allow` + paired debugserver, the `usbmuxd`
  socket, OpenSSL linkage), why it is out of reach for a sandboxed app, what ZynSign does
  instead, and the triggers that would reopen it. `PairingCapability` carries per-capability
  `feasibilityNote` + `documentationAnchor`, rendered by Settings → Pairing / JIT / Mux.

- **Capability tests** — `PairingCapabilityTests`, `AnalyticsPolicyTests`,
  `LocalAnalyticsJournalTests`, `InstallationDeliveryTests` pin every `supported == false`,
  the exact limitation sets, the journal contract (recency, counts, capacity pruning,
  corruption tolerance, clearing, persistence, redaction), and the manifest shape /
  HTTPS enforcement / link encoding.

- **Design System** — `ZCard`, `ZStatusBadge`, `ZSkeleton`, `ZProgressRing`, `ZToast`, `ZBottomSheet` +
  `DesignTokens` (ZDL v1.0), liquid glass, spring + haptics, Dark Mode. Four-layer
  `Presentation → Application → Domain ← Platform` via `CompositionRoot`.

- **Release automation** — `Scripts/generate_changelog.py` + `.github/workflows/release.yml`
  (auto changelog on `v*` tag) and `Scripts/update_readme.py` + `.github/workflows/update-readme.yml`
  (auto README badge sync from `MARKETING_VERSION` and `WHAT_DOES_NOT_EXIST`).

### Changed

- `MARKETING_VERSION` is `0.1.0` (numeric, App Store expectation); the `-dev` suffix
  lives only in history tags. `CURRENT_PROJECT_VERSION` is `4` for private + public (next build `5`).
- `AnalyticsPolicy` distinguishes off-device measurement (`isEnabled == false`, `eventCount == 0`,
  `endpoint == nil` — unchanged) from the local journal: new `journalDefaultsKey`, `journalCapacity`,
  `isJournalEnabled`, and a sixth guarantee `localJournalOnly`; `noTelemetry` is now
  `noTelemetryTransmission` ("No telemetry event ever leaves the device.").
- Settings → Installation / Pairing / Analytics copy updated for the hand-off, the feasibility
  notes, and the journal; README + `WHAT_DOES_NOT_EXIST.md` counts derived as `9 wired · 3 never`.
- `CodeDirectoryVersion` adds `v20400` (52 B, `supportsDEREntitlements`), `CodeDirectoryError` adds `derEntitlements`.
- `SignApplicationOptions.emitDEREntitlements` (default `false`) wires `v20200` / `v20400`.
- `IPAFileFormat` / `ImportablePackage` accept `tipa` as alias for `ipa`.

### Fixed

- `SigningView` diagnostic + `entitlementsSection` corruption (escaped newlines) — rebuilt clean.
- `InstallationEvidence` typo `.notValidated` → `.indeterminate` in `SettingsView`.

### Security

- No `kSecReturnData`, no key export, no `SecKeyCopyExternalRepresentation`; `CertificateExportService`
  exports public JSON only, `ShareSheet` is `fileprivate`, diagnostics redacted. Pairing / Analytics
  declare no private entitlements and no telemetry. The local activity journal stores category /
  slug / outcome / time on-device only — no identifiers, no transmission; the private matrix
  verifies with a proxy. See `SECURITY.md`.

### Notes

- **Sideload only** — not App Store, not install-claiming. Deliver `Documents/Signed` via MDM / OTA + confirmation.
- **Private → public gate** — this tag (`v0.1.0`) is the privately tested commit (`docs/releases/private-testing.md`
  matrix on iOS 17 + iOS 18, two devices + simulator).
- **Branch** `arena/01a0d570-zynsign` (Horizon `58e604c` + installation delivery hand-off, local
  activity journal, pairing/JIT/mux feasibility record; market `0.1.0` build `4`).
  History tags `v0.1.0-dev` / `v0.1.1-dev` / `v0.2.0-dev` at `58e604c`.
- **External validation** (ZS-031, runs `36010725148` / `36011553668`): `codesign` accepts single-image,
  rejects pipeline bundle (`files2`-only seal); format fails iOS 15+ `0x20200`/`DER` — addressed by `0x20400` toggle,
  but no iOS trust or installability is claimed (`docs/architecture/external-validation.md`).
