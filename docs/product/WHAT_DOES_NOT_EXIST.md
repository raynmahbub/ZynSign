# What Does Not Exist — Honest Limitations

> ZynSign `0.1.0` (Genesis 0.1.0 → 0.2.0 Horizon) — the foundation plus the ten honest rows now wired. This file stays the anti-roadmap: what is still *not* claimed, so no one mistakes a local success for platform trust. Details in `docs/architecture/installation-compatibility.md` and `docs/releases/version-strategy.md`.

## ✅ Now Exists (since 0.1.0 Horizon)

| Feature | Status | What you see |
|---|---|---|
| **Real entitlements** | Derived from profile (`0.1.1-dev`) | `SigningView` extracts `Entitlements` via bounded `CMSStructureReader` + `PropertyListProvisioningProfileParser` → `CodeSigningEntitlements(profileEntitlements:)` (unknown keys preserved, canonical XML ordering). Falls back to empty only when derivation fails. |
| **Export / Backup of certificates** | Public-metadata backup (`0.1.0`) | `CertificateDetailView` → `CertificateExportService` exports public JSON (subject/issuer/serial/SHA-256/notBefore/notAfter/keyInfo) in `tmp/ZynSign-Export/*.json` and shares via `UIActivityViewController`. Private key never exported — keep your `.p12` secure. |
| **Repository browser health** | `Fast`/`Slow`/`Offline` (`0.1.0`) | `AppStoreViewModel.Source` now carries `health` + `latencyMs`. `RepositoryHealthProbe` (3 s timeout, JSON validation) runs on `refresh()` and on-demand `Check Health` context menu. Row shows `ZStatusBadge` `Fast`/`Slow`/`Offline` + ms. |
| **DER entitlements / iOS 15+ `0x20400`** | Emitted when toggled (`0.1.0`) | `DEREntitlementsSerializer` produces deterministic DER SET (`DEREntitlementsBlob` `0xFADE7172` → slot 7) and `CodeDirectoryVersion.v20400` (52-byte header, slot 7 gated). Toggle in `SigningView` ( `0x20200` slot 5 only vs `0x20400` slot 5+7). `SignApplicationPipeline` wires `emitDEREntitlements` → `cdVersion`. |
| **Background downloads with pause/resume** | `BackgroundURLSession` (`0.1.0`) | `BackgroundDownloadService` (`com.zynsign.downloads`) hosts the background `URLSession` (resumeData, 600 s resource timeout). `DownloadsViewModel` uses it on device (foreground on simulator), exposes Pause/Resume/Cancel, retry ×3, checksum, and survives backgrounding. |
| **Live Activities / Dynamic Island** | `LiveActivityKit` wrapper (`0.1.0`) | `LiveActivityService` (`@MainActor`, `ActivityKit` on iOS 16.1+) mirrors `ZynSignLiveActivityState` (stage/progress/detail) to `@Published` and (when widget present) to the system. `SigningView` starts → updates (0.2/0.9) → ends around the 9-stage pipeline. Simulator degrades to in-app `ZStatusBadge`. |
| **Automation / Mission Control “Refresh Everything”** | Wired (`0.1.0`) | `HomeView` `MissionControl` card (`MissionControlService`) one-tap: repository refresh → library re-read → cache cleanup (`tmp` + `Downloads` pruning). Report shows `Completed`/`Unavailable` + counts + ms. Re-sign eligibility is policy-checked, never auto-triggered. |

## ❌ Still Honest — Not Claimed (Explicit Unavailable)

| Feature | Status | Why not, and what you see (code) |
|---|---|---|
| **Installation** | None — `InstallationCapabilityAssessment.deliveryMechanismAvailable == false` | No supported arbitrary-IPA install on iOS. `InstallationEvidence(profileStatus/deviceAuthorized/platformSupported)` → `InstallationAssessment(supported: false, limitations: [.noDeliveryMechanism, ...], summary)` (`Application/InstallationCapability.swift`). Settings → Installation shows `Unavailable` + `ZStatusBadge` + typed `noDeliveryMechanism` first. App does not claim to install. Deliver `Documents/Signed/*_signed.ipa` via MDM / OTA with user confirmation. See `docs/architecture/installation-compatibility.md`. |
| **Pairing / JIT / Mux / OpenSSL** | Never — `PairingCapabilityAssessment.allUnavailable` (`supported == false`) | No `PairingKit`, no `JITBroker`, no `usbmuxd`/`MobileDevice`, no OpenSSL linked into the app binary. `Application/PairingCapability.swift` models `pairing/jit/mux/openSSLLinkage` as `PairingAssessment(limitations: [.requiresPrivateEntitlement, .requiresLockdownDaemon, .notComposed])`. Settings → Pairing / JIT / Mux shows `Never` + per-capability `Unavailable` + limitations. OpenSSL only in `Tests/Host` external validation (`openssl cms -verify`), never linked. Keeps binary reviewable, avoids private-API risk. |
| **Analytics / Tracking** | None — `AnalyticsPolicy.isEnabled == false` | No `AnalyticsKit`, no telemetry, no crash-reporter SDK, no outbound endpoint, no identifier collection. `Application/AnalyticsPolicy.swift` (`isEnabled false`, `eventCount 0`, `endpoint nil`, 5 `Guarantee`s) is the single policy. Settings → Analytics shows `None` + `0 events` + `ZStatusBadge` + guarantees. Any future measurement requires ADR + port + platform + consent toggle. |

## What *does* exist instead

`Files → Library → Home → App Store → Downloads → Settings` shell, `ipa/tipa` import (bounded, security-scoped, SHA-256), durable library, bundle explorer, `CertificatesView` (`.p12/.pfx` 10 MiB → `SecureIdentityStore` + `ZStatusBadge` + **Export public JSON**), Smart Sign (`SigningView` + `ZProgressRing` + `ZSigningStatusMachine` 9 stages → `Documents/Signed` + `ZToast`/`ZBottomSheet` + **DER toggle 0x20400** + **Live Activity**), `Downloads` (**BackgroundURLSession pause/resume/retry/checksum**), `App Store` (**health Fast/Slow/Offline**), `Home` (**Mission Control Refresh Everything**), `DesignSystem` (`ZCard`/`ZStatusBadge`/`ZSkeleton`/`ZProgressRing`/`ZToast`/`ZBottomSheet` + `DesignTokens` + `ZDL v1.0`), `DEREntitlements` (`DEREntitlementsBlob` + `DEREntitlementsSerializer` + `CodeDirectoryVersion.v20400`).

## How to add these (when ready)

Per `CONTRIBUTING.md`: ADR → `Presentation/Features/<Feature>/Views` → `Application` port + `Platform` impl → Tests → `DesignSystem` UI → docs → CI green. `Packages/` extracts only when a second target needs it.

*If a screen claims one of the rows above as working beyond what this file says, the screen is wrong — file an issue with exact `ZynSignError` code.*
