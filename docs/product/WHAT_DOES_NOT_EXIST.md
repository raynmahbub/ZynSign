# What Does Not Exist — Honest Limitations

> ZynSign `v0.1.0-alpha.3` (market `0.1.0`, build `2`) — **10 staged · 7 on · 3 still ahead · 3 never**.
>
> **Wired** means the capability is compiled into the app and reachable. A Release
> build of `v0.1.0-alpha.3` switches on every feature up to and including that
> stop on the [release train](../releases/release-train.md); Debug builds show
> all of them.
> **Still ahead** means the code is present and tested but the train has not
> reached it — the rows below say which stop turns each one on.
> **Never** means no release will claim it: those rows are recorded decisions, not
> missing features.
>
> The count is the point. Ten features are staged; this build ships **seven** of
> them. The remaining three — Mission Control, the installation delivery
> hand-off, and the local activity journal — are `beta1`. Until the train gets
> there they are reachable in Debug and absent in Release, and this file will say
> so rather than let the badge imply otherwise.
>
> This file is the anti-roadmap. A local success is not platform trust, so this is
> what ZynSign still does **not** claim — and what it says instead. Details live in
> [installation-compatibility.md](../architecture/installation-compatibility.md),
> [pairing-jit-mux-feasibility.md](../architecture/pairing-jit-mux-feasibility.md)
> and [version-strategy.md](../releases/version-strategy.md).

## ✅ Now Exists

| Feature | Status | What you see |
|---|---|---|
| **Real entitlements** | Derived from profile | `SigningView` extracts `Entitlements` via bounded `CMSStructureReader` + `PropertyListProvisioningProfileParser` → `CodeSigningEntitlements(profileEntitlements:)` (unknown keys preserved, canonical XML ordering). Falls back to empty only when derivation fails. |
| **Signing engine execution** | Wired | `SigningEngineCoordinator` runs one attempt behind a single call: validation gate first, then the nine stages inside an isolated `SigningWorkingCopy` — inner-first nested signing, main-executable signing, an independent re-read verification of the signed copy, and packaging plus a container verification before anything reaches the delivery location. The original package is fingerprinted before and re-measured after; discarding reports the items and bytes reclaimed. `SigningView` shows a live row per stage with counts and an estimate, and a refusal names the stage, the reason, and the recovery facts. A failed run never leaves a partially signed artifact where it could look complete. |
| **Export / Backup of certificates** | Public-metadata backup | `CertificateDetailView` → `CertificateExportService` exports public JSON (subject/issuer/serial/SHA-256/notBefore/notAfter/keyInfo) in `tmp/ZynSign-Export/*.json` and shares via `UIActivityViewController`. Private key never exported — keep your `.p12` secure. |
| **Repository browser health** | `Fast`/`Slow`/`Offline` | `AppStoreViewModel.Source` carries `health` + `latencyMs`. `RepositoryHealthProbe` (3 s timeout, JSON validation) runs on `refresh()` and on-demand `Check Health` context menu. Row shows `ZStatusBadge` `Fast`/`Slow`/`Offline` + ms. |
| **DER entitlements / iOS 15+ `0x20400`** | Emitted when toggled | `DEREntitlementsSerializer` produces deterministic DER SET (`DEREntitlementsBlob` `0xFADE7172` → slot 7) and `CodeDirectoryVersion.v20400` (52-byte header, slot 7 gated). Toggle in `SigningView` (`0x20200` slot 5 only vs `0x20400` slot 5+7). `SignApplicationPipeline` wires `emitDEREntitlements` → `cdVersion`. |
| **Download Center** | Wired — not a background relaunch, and not universal resume | `DownloadCenter` queues transfers, validates archives before import, and hands off only after the user asks. `URLSessionDownloadTransfer` uses a foreground session with `waitsForConnectivity`. Pause reports resume data only when URLSession captured it. A killed process restores an in-flight job as interrupted, never completed. `DownloadTransferHonesty.claimsBackgroundRelaunch` and `claimsUniversalResume` are both false. |
| **Live Activities / Dynamic Island** | `LiveActivityKit` wrapper | `LiveActivityService` (`@MainActor`, `ActivityKit` on iOS 16.1+) mirrors `ZynSignLiveActivityState` (stage/progress/detail) to `@Published` and (when widget present) to the system. `SigningView` starts → updates (0.2/0.9) → ends around the 9-stage pipeline. Simulator degrades to in-app `ZStatusBadge`. |
| **Automation / Mission Control “Refresh Everything”** | Staged — `beta1` | `HomeView` `MissionControl` card (`MissionControlService`) one-tap: repository refresh → library re-read → cache cleanup (`tmp` + `Downloads` pruning). Report shows `Completed`/`Unavailable` + counts + ms. Re-sign eligibility is policy-checked, never auto-triggered. |
| **Installation delivery hand-off** | Staged — `beta1`; in-app install stays **unavailable** regardless | Sign → **Deliver…** → `InstallationDeliveryView` + `InstallationDeliveryService`: OTA `manifest.plist` (`itms-services`, Apple's documented shape), percent-encoded install link, on-device QR (Core Image `CIQRCodeGenerator`), and step guides for OTA / MDM / host tooling. HTTPS-only — `file://`/`http://` refused with a typed error. ZynSign never uploads, hosts, probes a server, or learns an install outcome. `InstallationCapabilityAssessment.deliveryMechanismAvailable == false` on every path — see `docs/architecture/installation-compatibility.md` § Delivery Hand-off. |
| **Local activity journal** | Staged — `beta1`; off-device measurement stays **none** regardless | `Settings → Analytics`: `LocalAnalyticsJournal` (JSONL in the app container, capacity 500) records category + fixed slug + outcome + time — never bundle IDs, paths, or device/user identifiers. Toggle (`AnalyticsPolicy.journalDefaultsKey`), live counts, recent activity, one-tap Clear, Export. `AnalyticsPolicy.isEnabled` (off-device) stays `false`, `eventCount 0`, `endpoint nil`, 6 typed guarantees incl. `localJournalOnly`. Nothing ever leaves the device. |

## ❌ Still Honest — Not Claimed (Explicit Unavailable)

| Feature | Status | Why not, and what you see (code) |
|---|---|---|
| **In-app installation** | None — `InstallationCapabilityAssessment.deliveryMechanismAvailable == false` | No supported arbitrary-IPA install on iOS. `InstallationEvidence(profileStatus/deviceAuthorized/platformSupported)` → `InstallationAssessment(supported: false, limitations: [.noDeliveryMechanism, ...], summary)` (`Application/InstallationCapability.swift`). Settings → Installation shows `Unavailable` + `ZStatusBadge` + typed `noDeliveryMechanism` first. The delivery hand-off produces operator artifacts; the **Installation Workspace** validates readiness, tracks deliveries the user started as pending attempts until the user confirms or abandons them, and keeps the Installed Apps Library as records the user confirmed — it never installs, never observes a device's app list, and never marks an interrupted attempt as installed. See `docs/architecture/installation-compatibility.md` and `docs/architecture/installation-workspace.md`. |
| **Pairing / JIT / Mux / OpenSSL** | Never — `PairingCapabilityAssessment.allUnavailable` (`supported == false`) + ADR | No `PairingKit`, no `JITBroker`, no `usbmuxd`/`MobileDevice`, no OpenSSL linked into the app binary. `Application/PairingCapability.swift` models `pairing/jit/mux/openSSLLinkage` as `PairingAssessment(limitations: [.requiresPrivateEntitlement, .requiresLockdownDaemon, .notComposed])` with per-capability `feasibilityNote` naming the private surface. Settings → Pairing / JIT / Mux shows `Never` + limitations + feasibility notes + anchors. Feasibility record: `docs/architecture/pairing-jit-mux-feasibility.md` (reopen triggers, boundaries). OpenSSL only in `Tests/Host` external validation (`openssl cms -verify`), never linked. Pinned by `PairingCapabilityTests`. |
| **Off-device analytics / tracking** | None — `AnalyticsPolicy.isEnabled == false` | No `AnalyticsKit`, no telemetry sender, no crash-reporter SDK, no outbound endpoint, no identifier collection. `Application/AnalyticsPolicy.swift` (`isEnabled false`, `eventCount 0`, `endpoint nil`, 6 `Guarantee`s incl. `localJournalOnly`) is the single policy; the local journal above is the only event store that exists, and it cannot transmit. Settings → Analytics shows `None` + `0 events sent` + journal controls + guarantees. Any future off-device measurement requires ADR + port + platform + consent toggle. Pinned by `AnalyticsPolicyTests`. |

## What *does* exist instead

`Files → Library → Home → App Store → Downloads → Settings` shell, `ipa/tipa` import (bounded, security-scoped, SHA-256), durable library, bundle explorer, Certificate Manager (`CertificateManagerView` + `CertificateManagerModel`: `.p12/.pfx` 10 MiB → `SecureIdentityStore`, search/sort/filters, list/grid, expiration intelligence via `CertificateExpirationAssessment`, team/type extraction, local labels + default identity via `FileIdentityAnnotationsStore`, `CertificateDetailView` + **Export public JSON**), Smart Sign (`SigningView` + `SigningEngineCoordinator` + `ZProgressRing` + `ZSigningStatusMachine` 9 stages → isolated working copy → independent verification → `Documents/Signed` + **Export IPA** / **Open Details** / **Verify Again** / **Return to Library** + `ZToast`/`ZBottomSheet` + **DER toggle 0x20400** + **Live Activity**), `Downloads` (**Download Center: queue, validation before import, honest resume**), `App Store` (**health Fast/Slow/Offline**), `Home` (**Mission Control Refresh Everything**), `DesignSystem` (`ZCard`/`ZStatusBadge`/`ZSkeleton`/`ZProgressRing`/`ZToast`/`ZBottomSheet` + `DesignTokens` + `ZDL v1.0`), `DEREntitlements` (`DEREntitlementsBlob` + `DEREntitlementsSerializer` + `CodeDirectoryVersion.v20400`).

## How to add these (when ready)

Per `CONTRIBUTING.md`: ADR → `Presentation/Features/<Feature>/Views` → `Application` port + `Platform` impl → Tests → `DesignSystem` UI → docs → CI green. `Packages/` extracts only when a second target needs it.

*If a screen claims one of the rows above as working beyond what this file says, the screen is wrong — file an issue with exact `ZynSignError` code. The pairing/JIT/mux boundary is additionally pinned by `PairingCapabilityTests`, and the analytics policy by `AnalyticsPolicyTests`.*
