# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `docs/releases/version-strategy.md` for the pre-1.0 progression and
`docs/releases/private-testing.md` for the private → public gate.

> **Distribution:** Every `0.1.0` build is sideload / TestFlight only — no
> App Store submission and no install claim (see `docs/architecture/installation-compatibility.md`).

## [Unreleased]

Work after `0.1.0` toward the next development build. The three honest
rows from `0.1.0` become: Installation → operator delivery hand-off
(in-app install stays unavailable), Analytics → local on-device journal
(off-device measurement stays none), Pairing/JIT/Mux → never, now
ADR-recorded.

### Added

- **Installation delivery hand-off** — `Sign → Deliver…` opens
  `InstallationDeliveryView` (`Application/InstallationDelivery.swift`):
  enter the HTTPS address where you will host the signed IPA and ZynSign
  builds Apple's `itms-services` `manifest.plist`, a percent-encoded
  install link, an on-device QR code (Core Image `CIQRCodeGenerator`,
  `Platform/DeliveryQRCodeRenderer.swift`), and step guides for the three
  operator channels — OTA hosting, MDM, and host tooling. HTTPS-only by
  design (`file://`/`http://` refused with a typed
  `InstallationDeliveryError`). ZynSign never uploads, hosts, probes a
  server, or learns an installation outcome;
  `InstallationCapabilityAssessment.deliveryMechanismAvailable` stays
  `false` on every path. Design record:
  `docs/architecture/installation-compatibility.md` § Delivery Hand-off.

- **Local activity journal (on-device analytics)** — `Settings →
  Analytics` gains a small journal of what ZynSign has done:
  `LocalAnalyticsEvent` (category + fixed slug + outcome + time — no
  bundle identifiers, paths, or device/user identifiers), recorded by
  `FileLocalAnalyticsJournal` (JSONL in the app container, capacity 500,
  atomic writes, damaged lines skipped) behind the
  `LocalAnalyticsRecording` port (`Application/LocalAnalyticsJournal.swift`),
  composed in `CompositionRoot`. The screen shows a recording toggle
  (`AnalyticsPolicy.journalDefaultsKey`, default on), live counts, recent
  activity, one-tap Clear, and Export. Wired call sites: import
  (`import.accepted`/`import.rejected`), signing
  (`sign.succeeded`/`sign.refused`/`sign.failed`/`sign.cancelled`),
  certificate import, download outcomes, and delivery manifest
  generation. Events never leave the device.

- **Pairing/JIT/Mux feasibility record** — `docs/architecture/pairing-jit-mux-feasibility.md`:
  for each capability the private surface it needs (MobileDevice/lockdown
  entitlements, `get-task-allow` + paired debugserver, the `usbmuxd`
  socket, OpenSSL linkage), why it is out of reach for a sandboxed app,
  what ZynSign does instead, and the triggers that would reopen the
  decision. `PairingCapability` now carries per-capability
  `feasibilityNote` + `documentationAnchor`, rendered by Settings →
  Pairing / JIT / Mux.

- **Tests** — `PairingCapabilityTests` (every `supported == false`, exact
  limitation sets, redacted text, anchors), `AnalyticsPolicyTests`
  (measurement off, guarantee set, journal preference default and
  override), `LocalAnalyticsJournalTests` (in-memory + file journals:
  recency, counts, capacity pruning, corruption tolerance, clearing,
  persistence, redaction contract), `InstallationDeliveryTests` (manifest
  shape, XML round-trip, HTTPS enforcement, `itms-services` encoding,
  written artifact, honest channel text).

### Changed

- **Analytics policy** — `AnalyticsPolicy` now distinguishes off-device
  measurement (`isEnabled == false`, `eventCount == 0`, `endpoint == nil`
  — unchanged) from the local journal: new `journalDefaultsKey`,
  `journalCapacity`, `isJournalEnabled`, and a sixth guarantee
  `localJournalOnly`; `noTelemetry` is now `noTelemetryTransmission`
  ("No telemetry event ever leaves the device."). Settings → Analytics and
  Settings → Installation copy updated to match.
- **Docs** — README rows/badge (`9 wired · 3 never` — the three nevers are
  narrower than `0.1.0`'s: in-app installation and off-device measurement,
  not delivery or analytics outright),
  `WHAT_DOES_NOT_EXIST.md` (hand-off and journal join "Now Exists",
  in-app install and off-device measurement stay claimed-never),
  `docs/architecture/README.md` index. Historical `docs/releases/*` and
  `docs/audits/*` still describe the shipped `0.1.0` binary and were
  deliberately left untouched.

## [0.1.0] - 2026-09-25

First public development build — **Horizon** — on `arena/01a0d4c7-zynsign`.
Market `0.1.0` build `3` (`CFBundleShortVersionString 0.1.0`, `CFBundleVersion 3`),
tag `v0.1.0`. The same binary is tested privately (TestFlight internal / ad-hoc IPA)
and then published — no rebuild between private and public.

This release completes `docs/product/WHAT_DOES_NOT_EXIST.md`: **7 wired, 3 honest**
(Installation / Pairing / Analytics explicitly unavailable). Signed output is
`Documents/Signed/*_signed.ipa` with Share.

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
  `Settings → Installation` `Unavailable`), `PairingCapability` (`allUnavailable`, `Settings → Pairing` `Never`),
  `AnalyticsPolicy` (`isEnabled == false`, `0 events`, 5 guarantees, `Settings → Analytics` `None`).
  See `docs/product/WHAT_DOES_NOT_EXIST.md` for code references.

- **Design System** — `ZCard`, `ZStatusBadge`, `ZSkeleton`, `ZProgressRing`, `ZToast`, `ZBottomSheet` +
  `DesignTokens` (ZDL v1.0), liquid glass, spring + haptics, Dark Mode. Four-layer
  `Presentation → Application → Domain ← Platform` via `CompositionRoot`.

- **Release automation** — `Scripts/generate_changelog.py` + `.github/workflows/release.yml`
  (auto changelog on `v*` tag) and `Scripts/update_readme.py` + `.github/workflows/update-readme.yml`
  (auto README badge sync from `MARKETING_VERSION` and `WHAT_DOES_NOT_EXIST`).

### Changed

- `MARKETING_VERSION` is now `0.1.0` (numeric, App Store expectation); the `-dev` suffix
  lives only in history tags. `CURRENT_PROJECT_VERSION` is `3` for private + public (next build `4`).
- `CodeDirectoryVersion` adds `v20400` (52 B, `supportsDEREntitlements`), `CodeDirectoryError` adds `derEntitlements`.
- `SignApplicationOptions.emitDEREntitlements` (default `false`) wires `v20200` / `v20400`.
- `IPAFileFormat` / `ImportablePackage` accept `tipa` as alias for `ipa`.

### Fixed

- `SigningView` diagnostic + `entitlementsSection` corruption (escaped newlines) — rebuilt clean.
- `InstallationEvidence` typo `.notValidated` → `.indeterminate` in `SettingsView`.

### Security

- No `kSecReturnData`, no key export, no `SecKeyCopyExternalRepresentation`; `CertificateExportService`
  exports public JSON only, `ShareSheet` is `fileprivate`, diagnostics redacted. Pairing / Analytics
  declare no private entitlements and no telemetry. See `SECURITY.md`.

### Notes

- **Sideload only** — not App Store, not install-claiming. Deliver `Documents/Signed` via MDM / OTA + confirmation.
- **Private → public gate** — this tag (`v0.1.0`) is the privately tested commit (`docs/releases/private-testing.md`
  matrix on iOS 17 + iOS 18, two devices + simulator).
- **Branch** `arena/01a0d4c7-zynsign` at `afcb316` (Horizon `58e604c` + market `0.1.0` build `3`).
  History tags `v0.1.0-dev` / `v0.1.1-dev` / `v0.2.0-dev` at `58e604c`.
- **External validation** (ZS-031, runs `36010725148` / `36011553668`): `codesign` accepts single-image,
  rejects pipeline bundle (`files2`-only seal); format fails iOS 15+ `0x20200`/`DER` — addressed by `0x20400` toggle,
  but no iOS trust or installability is claimed (`docs/architecture/external-validation.md`).

---

Full history since inception is preserved in git (`git log --oneline`) and in previous
changelog drafts. This file starts its professional history at `0.1.0`.

[Unreleased]: https://github.com/raynmahbub/ZynSign/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/raynmahbub/ZynSign/releases/tag/v0.1.0
