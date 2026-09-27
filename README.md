# ZynSign

<p align="center">
  <strong>On-device signing, made Apple-quality.</strong><br/>
  Inspect · Library · Certificate Studio · Smart Sign — inside the sandbox, no desktop helper.
</p>

<p align="center">
  <a href="docs/releases/version-strategy.md"><img alt="Version" src="https://img.shields.io/badge/version-0.1.0-orange"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="docs/architecture/architecture.md"><img alt="Architecture" src="https://img.shields.io/badge/architecture-ZAS%20v1.0-lightgrey"></a>
  <a href="docs/product/WHAT_DOES_NOT_EXIST.md"><img alt="Honest" src="https://img.shields.io/badge/honest-10%20wired%20·%203%20never-green"></a>
</p>

> **0.1.0 Horizon (2026-09-25) — release train**  
> The whole app is built: import, inspection, library, **Certificate Studio**, **Smart Sign (engine run · 9 stages · independent verification · DER 0x20400 · Live Activity)**, **Repository Health**, **Background Downloads**, **Mission Control**, **Installation Delivery Hand-off (OTA manifest + QR + operator guides)**, and a **Local Activity Journal (on-device, never transmitted)**. It ships **one release at a time**: `0.1.0` shows Files, Import, Library and Bundle Explorer, and each alpha switches on more (see [Release train](#release-train)). In-app installation remains a platform fact (`noDeliveryMechanism`); Pairing/JIT/Mux stays **never** (ADR-recorded); off-device analytics stays **off**.

---

## Why ZynSign

Sideloading on iOS is a maze of certificates, entitlements, provisioning profiles, and silently-failing signing steps. Most apps in the space treat those as power-user territory.

**ZynSign makes the hard parts — certificates, entitlements, troubleshooting, maintenance — feel like a first-party iOS app.** Built end-to-end inside the sandbox with no desktop helper, no remote service, and no analytics exfiltration: import an IPA, sign it, deliver it — with the same calm, structured feedback you expect from a system app.

| Users want | ZynSign answers with |
|---|---|
| **Effortless signing** | **Smart Sign** — `SigningView` + `SigningEngineCoordinator` (isolated working copy, independent verification) + `ZProgressRing` + 9-stage `ZSigningStatusMachine`, profile-derived entitlements, `DER 0x20400` toggle |
| **Entitlement clarity** | **[Entitlements Studio](docs/architecture/entitlements-studio.md)** — read-only app claims, capability cards, profile comparisons, Smart Diagnostics and JSON reports; no platform-acceptance prediction |
| **Certificate clarity** | **Certificate Studio** — `CertificateManagerView` lists Keychain identities with `WhenUnlockedThisDeviceOnly` + `ZStatusBadge`/`Health` + **Export public JSON** (private key never leaves) |
| **Apple-quality UI** | **Design Language (ZDL v1.0)** — `ZCard`/`ZSkeleton`/`ZProgressRing`/`ZToast`/`ZBottomSheet` + `DesignTokens` + liquid glass, spring + haptics, Dark Mode |
| **Plain diagnostics** | **Human errors** — `CERT_002 → “Wrong provisioning profile.”` via `ZynSignError` + `DiagnosticCategory` + `ZToast` |
| **One-tap maintenance** | **Mission Control** — `Home` `Good Evening · 12 Apps · Certificates Healthy · Expires in 28d → [Refresh Everything]` (`MissionControlService`) |
| **Trustworthy updates** | **Repository Intelligence** — `App Store` `Fast`/`Slow`/`Offline` health + `latency ms` (`RepositoryHealthProbe` 3 s) |

Full product identity: [`docs/product/UNIQUE_VALUE_PROPOSITION.md`](docs/product/UNIQUE_VALUE_PROPOSITION.md) · Honest limits: [`docs/product/WHAT_DOES_NOT_EXIST.md`](docs/product/WHAT_DOES_NOT_EXIST.md)

---

## Release train

Features are finished and compiled in. `ReleaseTrain.current` in [`ReleaseTrain.swift`](ZynSign/Application/ReleaseTrain.swift) decides which ones a Release build shows. Full procedure: [`docs/releases/release-train.md`](docs/releases/release-train.md).

| Release | Switches on |
|---|---|
| **`v0.1.0`** ◀ current | Home Dashboard · Import · Library (grid/list, search, sort, favourites) · Bundle Explorer · Certificates · Profiles · Settings |
| `v0.1.0-alpha.1` | Certificate Studio · Advanced Library (collections, smart collections, stackable filters, statistics, bulk and quick actions) |
| `v0.1.0-alpha.2` | Smart Sign (+ Signing Options, Installation screen) · Professional Signing Queue · Intelligent Signing Presets |
| `v0.1.0-alpha.3` | Entitlements Studio · App Store + Repository Health · Background Downloads |
| `v0.9.0-beta.1` | Mission Control · Delivery Hand-off · Activity Journal — **feature complete** |
| `v0.9.0-beta.2` | Installation Workspace (readiness, Installed Apps Library, confirmed deliveries, history) |
| `v0.9.0-beta.3…4` → `v1.0.0-rc.1…3` → `v1.0.0` | Batch Signing, then fixes |

```sh
python3 Scripts/release_train.py status     # what's visible now, what's next
python3 Scripts/release_train.py promote    # switch on the next release
```

Debug builds show everything. Add the launch argument `-ZynSignReleaseStage alpha2` to preview a specific release.

## What's built

The **Ships in** column is the first release that shows the feature.

| Area | State · Entry point | Notes |
|---|---|---|
| **Home Dashboard** <br/><sub>Ships in `v0.1.0`</sub> | `HomeView`: welcome header, Quick Actions (`Import IPA · Certificates · Profiles`), Recently Imported, Library statistics, first-launch onboarding | Every count read from the same use cases the tabs read; onboarding steps complete only when the store actually holds something |
| **Import — Smart Import Hub** <br/><sub>Ships in `v0.1.0` · Hub added in Step 13</sub> | `ImportHubView`, the one destination for the Files picker (multi-select), share sheet, Open In, the Files browser, iPad drag & drop (Home, Library, Import buttons, the hub's drop zone), and ⌘I / ⌘O. Accepts `ipa` / `tipa` and `.zip` archives of packages (security-scoped, bounded, SHA-256) | Every file is its own item (Waiting → Preparing → Validating → Analyzing → Importing → Complete / Failed; at most two preparing at once) with progress, remaining work, Cancel and Retry. Nothing is stored before the **preview** is confirmed; conflicts with the library wait in the **Duplicate Resolution Center** (Keep Both / Replace Existing / Skip, Apply to All, suggestions from version rules, never applied silently). Analysis reads icon, signing presence (not verified), frameworks, extensions. Summary (Imported / Skipped / Replaced / Failed) and on-device history with reopen. ZIPs are classified before extraction; unsafe, duplicated or linked entries refuse the archive. Free space is checked before every copy; interrupted items resume from surviving working copies. Imports continue only while ZynSign is open (plus iOS's short background extension). Rejects >100k entries, depth >32, >4 MiB inspection / 512 MiB extraction. Originals only read; staged in `tmp` by default (Settings → Advanced can move the workspace), adopted to `Application Support/ZynSignLibrary` |
| **Library** <br/><sub>Ships in `v0.1.0`</sub> | Durable `FileApplicationRecordStore` + `FileLibraryArtifactStore`, `isArtifactAvailable`, `BundleExplorerView` read-only, row `⋯ → Sign`; **grid/list cards** with extracted icons (`AppIconExtraction`, cached, honest monogram fallback), search by name/bundle ID, sort by recency/name/version, **favourite** + **Details** + **Delete** swipe actions, **multi-selection** bulk delete, signing-status badge from the on-device journal | Survives relaunch, duplicate SHA-256, missing-artifact badge. Catalog schema 2 (favourites); schema 1 converts on read |
| **Advanced Library** <br/><sub>Ships in `v0.1.0-alpha.1`</sub> | Library scope bar (All Apps · Favorites · Recently Imported · Recently Signed · Unsigned · Expiring Soon · your collections), **statistics** (apps, favourites, signed, unsigned, collections, storage), **collections** (create/rename/delete, many-to-many, move/add/remove), **stackable filters** (favourites, signed, unsigned, recency, expiring, collection, latest/older version, team), **7 orders** (remembered), instant **search** across name/bundle ID/version/file/declared developer & team/collection with highlighting, **bulk bar** (favourite, move, export, verify, remove, delete), **quick actions** as swipes + context menus, Home **Favorites** card | One `LibraryIndex` answers every query; small changes patch it. Collections in `ZynSignLibrary/Organization.json` (schema 1). *Signed* = a successful ZynSign signing in the on-device journal (signing-derived parts also need Smart Sign). *Verify* compares bytes with the import fingerprint — not a signature check. Developer/team are what the package declares |
| **Certificates** <br/><sub>Ships in `v0.1.0-alpha.1`</sub> | **Certificates tab** → `CertificateManagerView` + `CertificateDetailView` | `.p12/.pfx` 10 MiB, `ApplePKCS12Importer` → `SecureIdentityStore` (`WhenUnlockedThisDeviceOnly`, non-extractable), `ZStatusBadge` readiness, **Export public JSON** (`CertificateExportService` `tmp/ZynSign-Export/*.json` via share sheet) — private key never exported |
| **Profiles** <br/><sub>Ships in `v0.1.0`</sub> | **Provisioning Profile Manager** (`ProfilesView`): import `.mobileprovision` (`ProvisioningProfileImporter`) with an import-summary sheet, grid/list cards with team, type, devices, import date, expiry countdown and compatibility badge, search + sort + type/expiration filters, detail with General / Application / Distribution facts, five pre-sign compatibility checks + diagnostics panel, quick actions (View Details · Use for Signing · Copy Team ID/Bundle ID · Refresh Validation · Remove), automatic per-app profile suggestions with manual override | Summaries read from each profile's own declarations; original files kept beside the catalog for signing; compatibility and suggestions are device-local pre-sign checks, not trust or authenticity verdicts |
| **Entitlements Studio** <br/><sub>Ships in `v0.1.0-alpha.3`</sub> | `Library → App Details → Entitlements Studio` (also inside Signing) | Capability cards, counts, instant search/status filters, read-only inspectors, App/Profile comparison, shared selections, Smart Diagnostics and JSON export. Main-executable XML claims per architecture; unsupported checks stay explicit. [Scope and validation](docs/architecture/entitlements-studio.md) |
| **Smart Sign** <br/><sub>Ships in `v0.1.0-alpha.2`</sub> | `Library → ⋯ → Sign` / `Detail → Sign` → `SigningView` | One engine run (`SigningEngineCoordinator`): validation gate → 9 stages (integrity → profile → discovery → extraction → nested → sealing → main → packaging → verification) inside an isolated working copy, then an independent re-read verification before the IPA is delivered — the imported package is never signed and a refusal never leaves a partially signed artifact. Profile-derived `CodeSigningEntitlements` (CMS `CMSStructureReader` + `PropertyListProvisioningProfileParser`), **DER toggle** `0x20200` `slot 5` ↔ `0x20400` `slot 5+7` (`DEREntitlementsSerializer` `0xFADE7172`), **Live Activity** (`LiveActivityService` `ActivityKit` on 16.1+ else `ZStatusBadge`), export actions **Export IPA · Open Details · Verify Again · Return to Library** → `Documents/Signed/*_signed.ipa` + Share |
| **Signing Queue** <br/><sub>Ships in `v0.1.0-alpha.2`</sub> | `Library → Queue` / `Select → Queue Selected` / `Detail → Add to Queue` / `Sign → Add to Signing Queue Instead` / Import Hub → **Queue for Signing** / Settings → `SigningQueueView` | Job-based signing (`SigningQueue`): each job is one `SigningOperationCenter` operation (isolated workspace, independent verification, committed to **Exports**, recorded in signing history). High/Normal/Low priorities, Move Up/Down/Send to Top, live weighted stage progress (no fake jumps), Cancel/Retry (clean re-run)/Details/Remove, no Pause (no safe checkpoint), per-job log, revisioned persistence (interrupted runs never marked completed), bulk operations with confirmation, app-lock authorization at enqueue, toasts + VoiceOver + opt-in local notifications. See `docs/architecture/signing-queue.md` |
| **Intelligent Signing Presets** <br/><sub>Ships in `v0.1.0-alpha.2`</sub> | Settings → Signing Presets · Home → Presets · App details and Sign → Recommended Preset · Library selection → Sign with Preset · Import Hub → Ready to Sign | Reusable templates store a certificate fingerprint, a profile reference, team, entitlements slot, verification preference, and export behavior — not a key, a password, or profile bytes. Matching recommends; it does not sign. Confirming, after the app lock, enqueues compatible apps on the Signing Queue. See `docs/architecture/signing-presets.md` |
| **Repository browser** <br/><sub>Ships in `v0.1.0-alpha.3`</sub> | `App Store` (`AppStoreView`) AltSource feed, Featured + All, add/remove sources | **Health** `Fast` (<800 ms) / `Slow` (<3000 ms) / `Offline` (`RepositoryHealthProbe` 3 s, JSON validation, `ZStatusBadge` + `Check Health`) |
| **Downloads** <br/><sub>Ships in `v0.1.0-alpha.3`</sub> | `Downloads` (`DownloadsView`) `https` / `itms-services` / `manifest.plist` | **BackgroundURLSession** `com.zynsign.downloads` (resumeData, 600 s, retry ×3, checksum), `Pause`/`Resume`/`Cancel`, progress, survives backgrounding (foreground on Simulator) |
| **Mission Control** <br/><sub>Ships in `v0.9.0-beta.1`</sub> | `Home` (`HomeView`) + `MissionControlService` | **Refresh Everything**: sources → library re-read → cache cleanup (`tmp` 24h + `Downloads` 500 MiB/7d) with report `Completed`/`Unavailable` + counts + ms |
| **Design System** | `DesignSystem/` `ZCard/ZStatusBadge/ZSkeleton/ZProgressRing/ZToast/ZBottomSheet` + `DesignTokens` | ZDL v1.0, `Four-layer` `Presentation→Application→Domain←Platform` via `CompositionRoot` |
| **Provisioning** | Payload parsing, CMS verification, policy (`9 categories`), staged pipeline + bundle intake | Below UI; no trust/authorization claim |
| **Packaging** | Deterministic `PackageSignedApplication` + `DirectoryArchiveExtractor` (confinement, symlink `.exclude`) | Built at composition root |
| **Installation** <br/><sub>Ships in `v0.9.0-beta.1 (hand-off)` · `v0.9.0-beta.2 (workspace)`</sub> | **Hand-off + workspace wired · in-app install still honest-unavailable** `deliveryMechanismAvailable == false` | Sign → **Deliver…** → `InstallationDeliveryView` builds the OTA `manifest.plist` (`itms-services`), a copy-ready install link, an on-device **QR code** (Core Image), and step guides for OTA / MDM / host tooling. ZynSign never uploads, hosts, or learns an install outcome. **Installation Workspace** (Settings → Browse → Install, Home → Install, signing success): readiness checklists over the six checks ZynSign performs (signed · verified · package · export · identity · metadata — unknown reads *not performed*, never a pass), the **Installed Apps Library** of user-confirmed records with update states and contextual actions, **pending delivery attempts** that stay open across relaunches until you confirm or abandon them, flattened **history** with per-event detail, the **artifact relationship view** (Import → Signed → Exported → Delivery → Installed), **bulk preparation** (Verify All · Prepare All · Queue Selected · Retry Failed · Clear Completed — delivery is never bulk-started), and **storage awareness** with cleanups that never touch imported apps. See `docs/architecture/installation-workspace.md` |
| **Pairing/JIT/Mux** | **Never** — `PairingCapabilityAssessment.allUnavailable` + feasibility ADR | `Settings → Pairing` `Never` + `requiresPrivateEntitlement/requiresLockdownDaemon/notComposed` + per-capability `feasibilityNote` naming the private surface (usbmuxd, lockdown entitlements, `get-task-allow`). Record: `docs/architecture/pairing-jit-mux-feasibility.md`. OpenSSL only `Tests/Host` |
| **Analytics** | **Local journal wired · off-device measurement never** `AnalyticsPolicy.isEnabled == false` | `Settings → Analytics`: on-device **activity journal** (category + fixed slug + outcome — no identifiers/paths), toggle, live counts, recent activity, one-tap **Clear**, **Export**; 6 typed guarantees incl. `localJournalOnly`. No Kit/SDK/endpoint; nothing ever transmitted |
| **Build / Tests** | Xcode `ZynSign.xcodeproj` app + unit-test target; CI on iPhone simulator + host `external_validation.py` (`codesign`/`otool`/`openssl`) | Dependencies: Apple frameworks + Swift stdlib only |

### Sideload the build

The `0.1.0` build is **not App Store** — install via sideloading, TestFlight (if enrolled), or direct `Documents/Signed` delivery. See [`CHANGELOG.md`](CHANGELOG.md) and [`docs/releases/`](docs/releases/).

---

## Quick start

1. **Import** — `Home [Import IPA]` / `Library [+]` → pick `.ipa`/`.tipa` from Files. ZynSign stages → validates → fingerprints (SHA-256) → records. Duplicates are recognised; oversize is refused with a typed `ZynSignError`.
2. **Library** — the Library tab lists every application as a row or a grid card: icon, name, bundle ID, version + build, import date, signing status, favourite star. Search by name or bundle ID, sort by Recently Imported / Name / Version, swipe (or context-menu) for **Favorite · Details · Delete**, use **Select** for multi-selection. `Detail → Explore IPA` (tree, search, and a bounded read-only preview of a file you open; no extraction, links never followed, a signature command is not a trust verdict); `Detail → Sign` when signing is composed. Where the Advanced Library is switched on: pick a scope (Favorites, Recently Imported, … or a collection) from the bar under the statistics, stack filters from the filter menu, choose one of seven orders, and select apps to **Favorite · Move · Export · Verify · Delete** them from the floating bar.
3. **Certificates** — `Certificates tab → Import` → pick `.p12/.pfx` → password → `SecureIdentityStore`. Detail shows `Subject/Issuer/Serial/SHA-256/Valid From-Until/PublicKey/Association/Capability` + `ZStatusBadge ready/needsAttention`. `Export public JSON` shares metadata (private key never leaves).
4. **Profiles** — `Profiles tab → Import` → pick `.mobileprovision` → the import summary shows what was read; cards list name, team, type, devices, expiry (Healthy / Expiring Soon ≤ 30 d / Expired) and a compatibility badge. Search, sort, filter, or open a profile for its General/Application/Distribution facts, five pre-sign checks, and diagnostics; `Refresh Validation` re-reads the stored file. `Use for Signing` pins a profile; opening an app's detail suggests the best match for its bundle ID and lets you override per app.
5. **Sign** — `Library → ⋯ → Sign` → choose identity (ready) → choose `.mobileprovision` → entitlements auto-derived (`N from profile` + 8-key preview) → `DER 0x20400` toggle as needed → `Sign Application` → `ZProgressRing` + `ZSigningStatusMachine` + Live Activity → `Documents/Signed/*_signed.ipa` `Share` (or `Open in Files`). Failure shows `Refused at <stage>:` + `category`, no container delivered.
6. **Deliver** — `Sign → Deliver…` → enter the HTTPS address where you will host the signed IPA → ZynSign builds the `manifest.plist`, the `itms-services://…` install link, and a QR → publish both files on your host (or use MDM / Finder-Apple Configurator) → the device installs on user confirmation. ZynSign never uploads or claims an install.
7. **App Store / Downloads / Home** — `Settings → Browse → App Store` add AltSource `https://…/apps.json` → see `Fast/Slow/Offline`; `Get` → `Settings → Browse → Downloads` (pause/resume); `Home → Refresh Everything` for one-tap maintenance. `Settings → Analytics` shows the on-device activity journal — clearable, exportable, never transmitted.

---

## Repository layout

```
README.md                  This file
CHANGELOG.md               Notable changes, by release
CONTRIBUTING.md            How work is carried out (originality clause, ADR→Feature→…→CI)
SECURITY.md                Sensitive material + disclosure
LICENSE                    MIT
ZynSign/
  App/                     CompositionRoot, environment
  Application/             Use cases & ports (Import, Library, Sign, CertificateExport, RepositoryHealth, DER, BackgroundDownload, LiveActivity, MissionControl, InstallationDelivery hand-off, LocalAnalyticsJournal, Pairing/Analytics policy)
  Domain/                  Pure models (Archive, Bundle, Certificate, Provisioning, CodeDirectory 0x20001/0x20200/0x20400, Entitlements XML+DER, ResourceSealing, InstallationEvidence, etc.)
  Platform/                Apple implementations (Archive, Keychain, PKCS12, CMS, MachO, Downloads background, LiveActivity)
  Presentation/            SwiftUI: DesignSystem (ZCard/…/ZToast), 5-tab shell (Home/Library/Certificates/Profiles/Settings) + Files/App Store/Downloads, ApplicationLibrary grid+list, ProfilesView, SigningView + ZSigningStatusMachine, Settings/ Control Center (one descriptor + one catalog entry per section)
Tests/
  ZynSignTests/            Unit + fixture tests (domain, archive, import, library, certificates, provisioning, MachO, signing, metadata)
  Host/                    external_validation.py, verify_*.py (codesign/otool/openssl)
docs/
  architecture/            ZAS, signing pipeline, feasibility, external validation (0x20400, single-image vs pipeline)
  product/                 UNIQUE_VALUE_PROPOSITION.md, WHAT_DOES_NOT_EXIST.md (9 wired · 3 never — the three nevers are narrower than 0.1.0's)
  design/                  zynsign-design-language.md (ZDL v1.0)
  security/                provisioning-profiles, signing-identities, release-review
  releases/                version-strategy (0.1.0 Horizon), history
  development/             CI, toolchain
.github/
  workflows/ci.yml         Build + test (simulator) + host vector + external validation (non-gating)
```

---

## Architecture

**ZynSign Architecture Standard (ZAS v1.0)** — strict four-layer separation:

`Presentation → Application → Domain ← Platform` via `App/CompositionRoot`; `DesignSystem` is the only UI primitive (`ZCard`/`ZStatusBadge`/`ZSkeleton`/`ZProgressRing`/`ZToast`/`ZBottomSheet`, tokens `ZSpacing`/`ZRadius`/`ZColors`); no reach-through.

- **Domain** is pure, testable value types and policies (no `Foundation` I/O beyond `Data`/`Date`, no `UIKit`).
- **Application** owns ports (`ArtifactIntake`, `LibraryStore`, `IdentityStore`, `SigningPipeline`, `RepositoryHealthProbe`, …) and orchestrates Domain + Platform.
- **Platform** implements ports with Apple frameworks (`Security`, `CryptoKit`, `UniformTypeIdentifiers`, `BackgroundTasks/ActivityKit`).
- **Presentation** composes use cases and renders `Domain` state, never persistence or crypto directly.

Records live in `Application Support/ZynSignLibrary` (versioned catalog, SHA-256 dedupe, orphan sweep). Nothing leaves the sandbox.

Docs: [`docs/architecture/architecture.md`](docs/architecture/architecture.md) · [`docs/architecture/application-signing-pipeline.md`](docs/architecture/application-signing-pipeline.md) · [`docs/design/zynsign-design-language.md`](docs/design/zynsign-design-language.md)

---

## Security

Signing-adjacent material is sensitive. Read [`SECURITY.md`](SECURITY.md) before touching keys, credentials, profiles, or device data.

- Keys: `SecureIdentityStore` (`WhenUnlockedThisDeviceOnly`, `kSecAttrIsPermanent`, non-extractable, `kSecUseAuthenticationUI = fail`, duplicate `SHA-256` rejection, `association` + `capabilityState` checks per resolution).
- Diagnostics: redacted — no key material, profile bodies, file paths, or identifiers in user messages; `debugDescription` only where permitted.
- Vulnerabilities: reported privately per `SECURITY.md`.

Details: `docs/security/signing-identities.md` · `docs/security/provisioning-profiles.md` · `docs/security/release-review.md`

---

## Development

ZynSign is built in small, explicitly scoped increments:

- **Task-driven** — objective, explicit *create*, explicit *do not*, verifiable increment.
- **One branch per task** (`arena/<id>-zynsign`) until reviewed.
- **No speculative code** — no docs about non-existent functionality (or labelled `planned`).
- **Verifiable** — build / test / explicit “no check applies”.
- **Human-controlled Git** — commits/pushes/tags/releases by the developer; work lands on `main` through reviewed `arena/<id>-zynsign` branches.

Current release: `0.1.0` Horizon on the release train (market `0.1.0`, build `4`; public tag `v0.1.0` after the private matrix is green). Next: `v0.1.0-alpha.1` (Certificate Studio) via `python3 Scripts/release_train.py promote`.

```sh
git clone https://github.com/raynmahbub/ZynSign.git
cd ZynSign
open ZynSign.xcodeproj # Xcode 16+, iOS 17+ simulator
# Tests: Product → Test (⌘U) — domain + import + library + certs + provisioning + MachO + signing metadata
# Host vectors: Tests/Host/external_validation.py run  (macOS codesign/otool/openssl, non-gating)
```

Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md) — ADR → Feature → Application port → Platform impl → Tests → DesignSystem → docs → CI; `Packages/` only when a second target needs it.

---

## Honest limitations

No app claims to install arbitrary IPAs on stock iOS. ZynSign is explicit:

- **Installation** — `supports: false` on every path (`noDeliveryMechanism` first). No MDM/OTA/host flow is composed; signed output is `Documents/Signed` for you to deliver.
- **Pairing/JIT/Mux/OpenSSL** — never composed (would need `lockdown`/`MobileDevice` private entitlements). Keeps binary reviewable.
- **Analytics** — none. No Kit, no SDK, no endpoint, no identifier.

If a screen claims one of those as working, the screen is wrong — file an issue with the exact `ZynSignError` code.

Full anti-roadmap: [`docs/product/WHAT_DOES_NOT_EXIST.md`](docs/product/WHAT_DOES_NOT_EXIST.md) · Installability: [`docs/architecture/installation-compatibility.md`](docs/architecture/installation-compatibility.md) · External validation: [`docs/architecture/external-validation.md`](docs/architecture/external-validation.md)

---

## License

[MIT](LICENSE) — original software, written from scratch. See [`CONTRIBUTING.md`](CONTRIBUTING.md) originality clause and [`docs/product/UNIQUE_VALUE_PROPOSITION.md`](docs/product/UNIQUE_VALUE_PROPOSITION.md).
