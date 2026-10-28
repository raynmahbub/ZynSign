# What Does Not Exist — Honest Limitations

> ZynSign `v3.0.0-nova.1` (market `3.0.0`, build `11`) — **18 staged · 18 on · 0 still ahead · 3 never**.
>
> **Wired** means the capability is compiled into the app and reachable. A Release
> build of `v1.0.0` switches on every feature up to and including that stop on the
> [release train](../releases/release-train.md); Debug builds show all of them.
> **Still ahead** means the code is present and tested but the train has not
> reached it — the rows below say which stop turns each one on.
> **Never** means no release will claim it: those rows are recorded decisions, not
> missing features.
>
> The count is the point. Eighteen features are staged, and `3.0.0-nova.1` ships
> **all eighteen**: the Nova Assistant — the last one that was waiting — is on at
> this stop, and the stop that was scheduled between `1.0.0` and it (`v2.0.0`,
> depth and fixes) introduced no gate, so the train passes through it without
> holding anything back. Nothing is left ahead, and **nothing new is claimed** by
> that: the three *never* rows below are platform facts and recorded decisions,
> not work that this stop finished. In-app installation, pairing/JIT/mux, and
> off-device measurement stay exactly as recorded, and the app still names the
> requirement each one is missing rather than quietly offering a button that
> cannot work.
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
| **DER entitlements / iOS 15+ `0x20400`** | Serialized and read — **not embedded** | `DEREntitlementsSerializer` produces a deterministic DER SET (`DEREntitlementsBlob` `0xFADE7172` → slot 7) and `DEREntitlementsDecoder` reads it back into the same typed claim set, so a signature that carries only slot 7 reports its claims in the Entitlements Studio — the note names the slot it read, and a signature whose slots 5 and 7 disagree is stated rather than hidden. `CodeDirectoryVersion.v20400` (88-byte header with the exec-segment fields) exists. What does **not** exist is slot 7 in signed output: `SignApplicationPipeline` refuses `emitDEREntitlements` before any I/O (`unsupportedInput`, pinned by `SignApplicationPipelineTests`), `SigningDiagnosticsEvaluation` calls the option unsupported, and `SigningView` labels the toggle **Request DER entitlements (unsupported)**. Reading a DER slot is not authority to write one. |
| **Download Center** | Wired — not a background relaunch, and not universal resume | `DownloadCenter` queues transfers, validates archives before import, and hands off only after the user asks. `URLSessionDownloadTransfer` uses a foreground session with `waitsForConnectivity`. Pause reports resume data only when URLSession captured it. A killed process restores an in-flight job as interrupted, never completed. `DownloadTransferHonesty.claimsBackgroundRelaunch` and `claimsUniversalResume` are both false. |
| **Live Activities / Dynamic Island** | `LiveActivityKit` wrapper | `LiveActivityService` (`@MainActor`, `ActivityKit` on iOS 16.1+) mirrors `ZynSignLiveActivityState` (stage/progress/detail) to `@Published` and (when widget present) to the system. `SigningView` starts → updates (0.2/0.9) → ends around the 9-stage pipeline. Simulator degrades to in-app `ZStatusBadge`. |
| **Automation / Mission Control “Refresh Everything”** | Wired | `HomeView` `MissionControl` card (`MissionControlService`) one-tap: repository refresh → library re-read → cache cleanup (`tmp` + `Downloads` pruning). Report shows `Completed`/`Unavailable` + counts + ms. Re-sign eligibility is policy-checked, never auto-triggered. |
| **Installation delivery hand-off** | Wired; in-app install stays **unavailable** regardless | Sign → **Deliver…** → `InstallationDeliveryView` + `InstallationDeliveryService`: OTA `manifest.plist` (`itms-services`, Apple's documented shape), percent-encoded install link, on-device QR (Core Image `CIQRCodeGenerator`), and step guides for OTA / MDM / host tooling. HTTPS-only — `file://`/`http://` refused with a typed error. ZynSign never uploads, hosts, probes a server, or learns an install outcome. `InstallationCapabilityAssessment.deliveryMechanismAvailable == false` on every path — see `docs/architecture/installation-compatibility.md` § Delivery Hand-off. |
| **Local activity journal** | Wired; off-device measurement stays **none** regardless | `Settings → Analytics`: `LocalAnalyticsJournal` (JSONL in the app container, capacity 500) records category + fixed slug + outcome + time — never bundle IDs, paths, or device/user identifiers. Toggle (`AnalyticsPolicy.journalDefaultsKey`), live counts, recent activity, one-tap Clear, Export. `AnalyticsPolicy.isEnabled` (off-device) stays `false`, `eventCount 0`, `endpoint nil`, 6 typed guarantees incl. `localJournalOnly`. Nothing ever leaves the device. |

## ❌ Still Honest — Not Claimed (Explicit Unavailable)

| Feature | Status | Why not, and what you see (code) |
|---|---|---|
| **In-app installation** | Platform fact, now with a named requirement — see [sideloading.md](../architecture/sideloading.md) | The device bridge (`DeviceBridgeService`) speaks usbmuxd, lockdownd, AFC and installation_proxy, and `SideloadingCapability.assess(.packageInstallation)` reports what it is missing: an imported pairing record, a local-tunnel entitlement, and a build whose profile carries it. Until those are met the assessment says so per requirement instead of one badge; `InstallationCapabilityAssessment.deliveryMechanismAvailable` stays `false` for the hand-off path, which still never installs. `InstallationEvidence(profileStatus/deviceAuthorized/platformSupported)` → `InstallationAssessment(supported: false, limitations: [.noDeliveryMechanism, ...], summary)` (`Application/InstallationCapability.swift`). Settings → Installation shows `Unavailable` + `ZStatusBadge` + typed `noDeliveryMechanism` first. The delivery hand-off produces operator artifacts; the **Installation Workspace** validates readiness, tracks deliveries the user started as pending attempts until the user confirms or abandons them, and keeps the Installed Apps Library as records the user confirmed — it never installs, never observes a device's app list, and never marks an interrupted attempt as installed. See `docs/architecture/installation-compatibility.md` and `docs/architecture/installation-workspace.md`. |
| **Pairing / JIT / Mux / OpenSSL** | Revised — pairing composed behind an entitled transport; JIT still never; OpenSSL still host-only ([ADR](../architecture/pairing-jit-mux-feasibility.md)) | Pairing records, session start, service start, AFC upload and `installation_proxy` are implemented as wire protocols with no private framework and no daemon socket; the missing piece is the local tunnel entitlement, which is a distribution fact this repository cannot grant itself. JIT is still refused everywhere. No `MobileDevice`, no `usbmuxd` socket, no OpenSSL linked into the app binary. `Application/PairingCapability.swift` models `pairing/jit/mux/openSSLLinkage` as `PairingAssessment(limitations: [.requiresPrivateEntitlement, .requiresLockdownDaemon, .notComposed])` with per-capability `feasibilityNote` naming the private surface. Settings → Pairing / JIT / Mux shows `Never` + limitations + feasibility notes + anchors. Feasibility record: `docs/architecture/pairing-jit-mux-feasibility.md` (reopen triggers, boundaries). The entitlement requirement is **measured, not assumed**: `ProcessEntitlements` reads this build's own signature once at launch, so the screen distinguishes *granted*, *absent*, and *not established* (`docs/architecture/sideloading.md` § Read from the signature, not assumed) — an entitled build reads as entitled, and a build that could not be inspected says so instead of claiming absence. OpenSSL only in `Tests/Host` external validation (`openssl cms -verify`), never linked. Pinned by `PairingCapabilityTests`. |
| **Off-device analytics / tracking** | None — `AnalyticsPolicy.isEnabled == false` | No `AnalyticsKit`, no telemetry sender, no crash-reporter SDK, no outbound endpoint, no identifier collection. `Application/AnalyticsPolicy.swift` (`isEnabled false`, `eventCount 0`, `endpoint nil`, 6 `Guarantee`s incl. `localJournalOnly`) is the single policy; the local journal above is the only event store that exists, and it cannot transmit. Settings → Analytics shows `None` + `0 events sent` + journal controls + guarantees. Any future off-device measurement requires ADR + port + platform + consent toggle. Pinned by `AnalyticsPolicyTests`. |

## Stops the train settled, not deferred

No row of the release train now predicts a capability without a surface. Two
stops used to, and both were decisions rather than missing work:

| Feature | Stop | What happened |
|---|---|---|
| **Batch Signing** | `v0.9.0-beta.3` | **Retired.** The behaviour is already shipped, under a different gate: **Queue Selected for Signing…** (`ReleaseFeature.signingQueue`, since `v0.1.0-alpha.2`) applies one identity and profile to a whole selection and runs the jobs one at a time, journalled by `SigningOperationCenter`. The stop named a second label for that behaviour, and the only code carrying the name — `BatchSigningCoordinator`, which nothing constructs — delivers, names, verifies and journals differently, so a surface built on it would be a second signing path. `ReleaseFeature.batchSigning` no longer exists, `v0.9.0-beta.3` is a fixes-and-compatibility stop, and no user loses anything: the gate was never exposed. |
| **Signing Health Score** | `v1.0.0` | **Wired.** `SigningHealthScore` (0–100, banded) and `SigningHealthAssessment` (identity + profile + bundle → score and findings) now render as `SigningHealthScoreCard` on the Sign screen, recomputed whenever the selected identity, profile or bundle changes. The always-on `SigningDiagnosticsAnalysis` card on an application's detail screen is a different feature and keeps its own score. |
| **Nova Assistant** | `v3.0.0-nova.1` | **Wired.** `NovaAdvisor` turns the stores' own facts into at most six suggestions — expiring or expired certificates and profiles, a library without an identity, an identity without a profile, duplicate bundle identifiers, an application no profile covers, and a backup reminder — and `SmartWorkspaceView` renders them with a door to the screen that owns each one. It never acts, never signs, and never leaves the device. |
`Scripts/audit_release_gating.py` keeps the distinction visible and mechanical:
every `ReleaseFeature` must be referenced by the app's own source, and
`Scripts/ci/release-surface-deferrals.txt` is now empty. A deferral added in
future is a decision a reviewer can see, and repaying one fails the build until
the entry is deleted, so the list cannot outlive the gap it describes.

## What *does* exist instead

`Files → Library → Home → App Store → Downloads → Settings` shell, `ipa/tipa` import (bounded, security-scoped, SHA-256), durable library, bundle explorer, Certificate Manager (`CertificateManagerView` + `CertificateManagerModel`: `.p12/.pfx` 10 MiB → `SecureIdentityStore`, search/sort/filters, list/grid, expiration intelligence via `CertificateExpirationAssessment`, team/type extraction, local labels + default identity via `FileIdentityAnnotationsStore`, `CertificateDetailView` + **Export public JSON**), Smart Sign (`SigningView` + `SigningEngineCoordinator` + `ZProgressRing` + `ZSigningStatusMachine` 9 stages → isolated working copy → independent verification → `Documents/Signed` + **Export IPA** / **Open Details** / **Verify Again** / **Return to Library** + `ZToast`/`ZBottomSheet` + **DER toggle 0x20400** + **Live Activity**), `Downloads` (**Download Center: queue, validation before import, honest resume**), `App Store` (**health Fast/Slow/Offline**), `Home` (**Mission Control Refresh Everything**), `Settings → Devices → Sideloading` (**always on, `CoreFeature.sideloading`**: one row per capability naming the requirement it is missing — pairing record, local-tunnel entitlement, bundled loader — plus the package edits a signing run can apply), `DesignSystem` (`ZCard`/`ZStatusBadge`/`ZSkeleton`/`ZProgressRing`/`ZToast`/`ZBottomSheet` + `DesignTokens` + `ZDL v1.0`), `DEREntitlements` (`DEREntitlementsBlob` + `DEREntitlementsSerializer` + `CodeDirectoryVersion.v20400`).

## How to add these (when ready)

Per `CONTRIBUTING.md`: ADR → `Presentation/Features/<Feature>/Views` → `Application` port + `Platform` impl → Tests → `DesignSystem` UI → docs → CI green. `Packages/` extracts only when a second target needs it.

*If a screen claims one of the rows above as working beyond what this file says, the screen is wrong — file an issue with exact `ZynSignError` code. The pairing/JIT/mux boundary is additionally pinned by `PairingCapabilityTests`, and the analytics policy by `AnalyticsPolicyTests`.*
