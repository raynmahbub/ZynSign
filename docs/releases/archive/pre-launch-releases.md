# Archived pre-launch releases

_The three pre-launch GitHub releases, deleted on 2026-09-29 as step 1 of
[ReleaseResetGuide.md](../ReleaseResetGuide.md). Their bodies are reproduced
here verbatim so the reset destroys no information._

**Nothing on this page describes the current state of ZynSign.** These notes
were written for versions that are not stops on the release train and can never
be released again. For where the project stands now see
[release-train.md](../release-train.md) and
[version-strategy.md](../version-strategy.md).

| Tag | Title | Published | Pre-release |
| --- | --- | --- | --- |
| `v0.1.0-dev` | ZynSign 0.1.0-dev Genesis + 0.1.1 Real entitlements | 2026-09-24 | yes |
| `v0.1.1-dev` | ZynSign 0.1.1-dev Real entitlements (1/10) | 2026-09-24 | no |
| `v0.2.0-dev` | ZynSign 0.2.0-dev Horizon — first dev build | 2026-09-24 | no |

The tags all pointed at commit `58e604c`, which sat on a pre-merge branch and
was never an ancestor of `main`. With the tag refs deleted it is no longer
reachable from any ref — GitHub still serves the object, but nothing points at
it. The **work** those releases described is in `main`: it was merged, and
[CHANGELOG.md](../../../CHANGELOG.md) records it. Only the release objects,
their tag refs, and the notes below were removed, which is why the notes are
copied here.

---

## `v0.1.0-dev` — ZynSign 0.1.0-dev Genesis + 0.1.1 Real entitlements

Published 2026-09-24 · pre-release · tag `v0.1.0-dev` (deleted)

````markdown
# ZynSign 0.1.0-dev — first development build

**Tag:** `v0.1.0-dev` · **Marketing version:** `0.1.0-dev` · **Build:** `2` · **Date:** 2026-09-25  
**Distribution:** GitHub releases for sideloading / TestFlight testing only — not an App Store submission.

ZynSign is original software, written from scratch. It is not a fork or derivative of any other application. This is the first versioned build: import, inspection, the library, certificate import, `ipa`/`tipa` handling, and the nine-stage signing pipeline are now reachable from the interface.

See [`CHANGELOG.md`](https://github.com/raynmahbub/ZynSign/blob/main/CHANGELOG.md) for the full history and [`docs/releases/version-strategy.md`](https://github.com/raynmahbub/ZynSign/blob/main/docs/releases/version-strategy.md) for the release progression.

## What's new in 0.1.0-dev

### Highlights

This build makes the work that was previously below the interface reachable from the screens.

**Added**

- **Certificate import** — `SigningIdentityImporter` (`ApplePKCS12Importer`) imports PKCS#12 containers (`.p12` / `.pfx`, ≤10 MiB) through `SecPKCS12Import`, extracts the first identity, resolves the private-key persistent reference with a non-interactive `LAContext`, and registers the certificate DER plus key reference through `SecureIdentityStore`. Duplicate fingerprints are rejected, wrong passwords map to `authorizationFailure`, no key bytes are logged. Surfaced via `ApplicationEnvironment.identityStore` / `pkcs12Importer` and `Settings → Certificates`.
- **Certificates UI** — `CertificatesView` lists every registered identity (subject, issuer, fingerprint, validity, key availability, association, capability, readiness), imports via a broad `fileImporter` (`.data`/`.item` filtered to `.p12`/`.pfx`) plus a password sheet (password never stored), and removes registrations without deleting imported keys. Honors Keychain protection (`WhenUnlockedThisDeviceOnly`, non-extractable, non-synchronizable).
- **TIPA support** — `IPAFileFormat` now accepts `tipa` as an alias for `ipa` (`acceptedPathExtensions`), `ImportablePackage` vends dynamic `UTType`s for both extensions, `FilesView` shows `tipa` with `app.badge`, and the import pipeline stages a `tipa` as `ipa` so library, archive reader, and signing handle it identically.
- **Signing UI** — `SigningView` for any library entry (Library row ⋯ → Sign, Application Detail → Sign) composes the imported package, a chosen identity, and a `.mobileprovision` profile. It validates availability, lists identities with readiness, picks a profile via `fileImporter` (`.mobileprovision`), runs `SignApplicationPipeline` (`integrity → profile → discovery → extraction → nestedSigning → resourceSealing → mainExecutable → packaging → verification`) with an empty entitlement set (compatible with the synthetic test fixture profile; real profiles will need derived entitlements next), delivers the verified container to `Documents/Signed/<name>_signed.ipa`, and offers Share. Failures report the refusing stage and typed reason; no container is delivered on failure and the working copy is discarded.
- **Library signing integration** — `LibraryTabView` context menus and `ApplicationDetailView` now expose “Sign Application…”. Bulk delete remains; bulk sign deferred.
- **Files handling** — `FilesView.FileItem.icon` maps `tipa` → `app.badge`, `mobileprovision`/`provisionprofile` → `signature`; Downloads and Files importers accept both `ipa` and `tipa`.
- **Composition** — `ApplicationEnvironment` now carries `identityStore`, `pkcs12Importer`, `signingPipeline` plus `artifactFileURL(for:)`, and `CompositionRoot` constructs all three together. `UnavailableIdentityStore` / `UnavailablePKCS12Importer` remain as off-device fallbacks.

**Changed**

- `IPAFileFormat` and `ImportablePackage` handle `ipa` and `tipa` uniformly.
- `ApplicationEnvironment` is now the single seam for import, library, bundle inspection, identities, and signing.
- `Settings → Certificates` is no longer a placeholder; `Library` no longer reports “Signing not yet composed”.

**Security**

- Private-key bytes are never requested via `kSecReturnData`. Re-checks of public-key association, key class, accessibility, synchronizability, and extractability occur on every resolution; diagnostics stay redacted.

**History** — the full prior Unreleased development history (import/inspection/library, archive layer, bundle explorer, certificate/identity foundation, provisioning-profile pipeline, Mach-O inspection, experimental signing stack, packaging/extraction, external validation ZS-031, CI, and security review) is preserved in `CHANGELOG.md` under `0.1.0-dev → History since inception`.

## Installation

No IPA is attached to this release — this is a source-tagged development build. Build the Xcode project (`ZynSign.xcodeproj`, target `ZynSign`) on macOS with Xcode 15+ and deploy to a device or TestFlight:

```sh
xcodebuild -project ZynSign.xcodeproj -scheme ZynSign -configuration Release build
# or open in Xcode and run to a signed device / TestFlight
```

The project has no external dependencies — Apple frameworks and the Swift standard library only.

## Honest limitations — please read before relying on this build

- **Installation is unavailable.** No supported arbitrary-IPA installation mechanism is available to an iOS/iPadOS application. A pure `InstallationAssessment` reports installation as unavailable with exact limitations; see [`docs/architecture/installation-compatibility.md`](https://github.com/raynmahbub/ZynSign/blob/main/docs/architecture/installation-compatibility.md) and [`docs/architecture/application-signing-pipeline.md`](https://github.com/raynmahbub/ZynSign/blob/main/docs/architecture/application-signing-pipeline.md). This build does not claim to install anything.
- **Signing format and external validation.** Apple's desktop `codesign` accepts ZynSign's single-image signatures but rejects the pipeline's bundles ("code has no resources but signature indicates they must be present") and the signature format fails Apple's documented iOS 15+ requirements (CodeDirectory `0x20400`, DER entitlements). See [`docs/architecture/external-validation.md`](https://github.com/raynmahbub/ZynSign/blob/main/docs/architecture/external-validation.md). No iOS trust or installability is claimed.
- **Entitlements are empty in this build.** `SigningView` passes `CodeSigningEntitlements(values: [:])`. That is compatible with the synthetic fixture profile used in tests; real provisioning profiles will require derived entitlements in the next increment and will currently either fail or produce a container that does not satisfy profile policy on device.
- **Device validation outstanding.** The pipeline, the packager, the verifier, and the PKCS#12 importer are covered by simulator-gated and deterministic unit tests, but on-device validation with real developer identities and provisioning profiles has not yet been demonstrated (E1/E7-class lock/background/backup/reinstall and authorization behavior). The next step after 0.1.0-dev is exactly that device validation.
- **No secrets in the repository.** The build contains no private keys, credentials, or provisioning profiles; see [`SECURITY.md`](https://github.com/raynmahbub/ZynSign/blob/main/SECURITY.md).

## Verifying the build

- Tag `v0.1.0-dev` is annotated and pushed; the marketing version in `project.pbxproj` is `0.1.0-dev` build `2` across all configurations.
- `CHANGELOG.md` has a `[0.1.0-dev] - 2026-09-25` section with Highlights and preserved history.
- `docs/releases/README.md` and `docs/releases/version-strategy.md` record the produced build and the current position against the alpha/beta/RC/stable exits.
- Build on hosted CI: `ci.yml` builds the app target and runs unit tests on a simulator plus hygiene and external-validation jobs.

## What comes next

Device validation of certificate import, `tipa` handling, and single-target signing with real provisioning profiles, then derived entitlements and the alpha exit criteria in `version-strategy.md`. Until those hold, `0.1.0-dev` remains a development pre-release and the project says so.

---

*Built from `main` history plus the six-tab shell (Files, Library, Home, App Store, Downloads, Settings) that were previously below the interface and are now composed. Thank you for testing and for filing issues with exact diagnostics.*
````

## `v0.1.1-dev` — ZynSign 0.1.1-dev Real entitlements (1/10)

Published 2026-09-24 · marked as a full release · tag `v0.1.1-dev` (deleted)

````markdown
Step 1/10 from WHAT_DOES_NOT_EXIST.md: SigningView now derives entitlements from .mobileprovision via bounded CMSStructureReader + PropertyListProvisioningProfileParser -> CodeSigningEntitlements, preserving unknown keys, ZStatusBadge diagnostics. Genesis 0.1.0-dev foundation intact (43 files, DesignSystem, 6-tab shell, Smart Sign).
````

## `v0.2.0-dev` — ZynSign 0.2.0-dev Horizon — first dev build

Published 2026-09-24 · marked as a full release · tag `v0.2.0-dev` (deleted)

````markdown
## ZynSign 0.2.0-dev Horizon — first dev build (sideload-only, honest)

**Branch** `arena/01a0d4c7-zynsign` `58e604c` · **55 files `4784++`** · **Tags** `v0.2.0-dev` → `58e604c` · **README** professional · **CHANGELOG** 0.2.0-dev Highlights

### What works today (7 wired)
- **Real entitlements** — `SigningView` `CMSStructureReader` → `PropertyListProvisioningProfileParser` → `CodeSigningEntitlements` (preserve unknown, 8-key preview, `ZStatusBadge`)
- **Export/Backup** — `CertificateDetailView` → `CertificateExportService` public JSON `tmp/ZynSign-Export/*.json` via share (private key never leaves)
- **Repository health** — `RepositoryHealthProbe` 3s → `AppStoreViewModel.Source` `Fast <800ms` / `Slow <3000ms` / `Offline` + `latency ms` + `Check Health`
- **DER 0x20400** — `DEREntitlementsSerializer` `0xFADE7172` slot 7 + `CodeDirectoryVersion.v20400` gated, `SigningView` toggle `0x20200 slot5` ↔ `0x20400 slot5+7`
- **Background downloads** — `BackgroundDownloadService` `com.zynsign.downloads` (resumeData, 600s, retry×3, checksum) `Pause`/`Resume` + `Poll` (foreground on Simulator)
- **Live Activities** — `LiveActivityService` `ActivityKit` 16.1+ wrapper `ZynSignLiveActivityState` around 9-stage pipeline (degrades to `ZStatusBadge`)
- **Mission Control** — `Home` `MissionControlService` `refresh repositories → library re-read → cache cleanup` (tmp 24h + Downloads 500MiB) with report

### Honest 8-10 (explicit unavailable)
- **Installation** `None` — `InstallationCapabilityAssessment.deliveryMechanismAvailable == false` always, `Settings → Installation` `Unavailable` + `noDeliveryMechanism` first (see `docs/architecture/installation-compatibility.md`)
- **Pairing/JIT/Mux/OpenSSL** `Never` — `PairingCapabilityAssessment.allUnavailable` (`requiresPrivateEntitlement`/`requiresLockdownDaemon`/`notComposed`), `Settings → Pairing` `Never`; OpenSSL only `Tests/Host`
- **Analytics** `None` — `AnalyticsPolicy.isEnabled == false` (`0 events`, 5 guarantees), `Settings → Analytics` `None`

### Honesty
No supported arbitrary-IPA install on stock iOS. Signed output is `Documents/Signed/*_signed.ipa` + Share — deliver via MDM/OTA+confirm/host. `WHAT_DOES_NOT_EXIST.md` is the anti-roadmap (7 wired · 3 honest). No private API, no analytics.

### Install the build
Sideload / TestFlight (if enrolled) — not App Store. See `README.md` Quick start, `CHANGELOG.md` 0.2.0-dev, `docs/releases/version-strategy.md`.

### Publish checklist
- [x] `README.md` professional (badges, Why, What works, Quick start, Layout, ZAS, Security, Development, Honest)
- [x] `CHANGELOG.md` 0.2.0-dev Highlights/Added/Changed/Fixed/Security/Notes
- [x] `WHAT_DOES_NOT_EXIST.md` 0.2.0 ✅ 7 + ❌ 3 explicit
- [x] `ZAS` `Presentation→Application→Domain←Platform` via `CompositionRoot`, `DesignSystem` `Z*` only
- [x] No `/.ai/`, no `Generated by`, no private keys, no `AnalyticsKit`
- [x] Branch `arena/01a0d4c7-zynsign` force-pushed `58e604c`, tags `v0.2.0-dev` annotated, release `arena/01a0d4c7-zynsign`

> Ready to publish first dev build.
````
