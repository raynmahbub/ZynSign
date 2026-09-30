<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# ZynSign v3.0 “Nova” — The Complete iOS Signing Platform

**Theme: One Workspace. Complete Control.**

v3.0 turns ZynSign from an IPA signer into a workspace for iOS apps —
analysis, signing, delivery hand-off, management, and on-device
intelligence — without adding a fifth layer, a server, or a claim the
device cannot back. Every feature below is placed in the existing
architecture (`Presentation → Application → Domain ← Platform`, composed in
`App/CompositionRoot`) and switched on by the release train like everything
before it.

| | |
|---|---|
| Status | **In progress.** The Smart Workspace home (Mission Control) is introduced by the `rc2` stop because it is polish over existing features, not a new capability. The Nova Assistant is in the tree behind `ReleaseStage.nova1`; the rest of this document is planned. |
| Train | `v0.0.1-dev.1` → the first build → the alphas (**current: `v0.1.0-alpha.3`**) → the betas → the RCs → `v1.0.0` → `v2.0.0` (depth, no new gates) → `v3.0.0-nova.1` (Nova Assistant) → `v3.0.0` (the rest of this document). |
| Preview | Debug builds show everything; `-ZynSignReleaseStage nova1` previews the exact release. |
| Nevers | Unchanged: no in-app installation claim, no Pairing/JIT/Mux, no off-device analytics. Nova is rule-based and on-device; it recommends, it never acts. |

## Design principles for Nova

1. **Upgrade, don't duplicate.** Health Score, Binary Inspector, Collections,
   Signing Queue, Backup, Live Activity, Haptics, and the Identity Center
   already exist. Nova features are new *surfaces* and *policies* over the
   same stores — one library, one identity store, one profile library, one
   journal — so nothing can disagree with a tab.
2. **Domain first.** Every Nova rule is a pure function with a clock
   argument (`NovaAdvisor`, `WorkspaceLayoutPolicy`, `InstallHealthReport`),
   tested without a store or a view.
3. **Honest states survive.** A check that did not run is *not performed* and
   counts against the score; a suggestion says what was observed and where to
   act; “Install Health” never says *installed*.
4. **One motion and haptic language.** The Z·Pen mark (`ZynSignMark`) and the
   ribbon motion are the visual thread through splash, progress, success,
   empty states, and onboarding. Springs at 300–500 ms, Reduce Motion always
   honoured — the rules in [`zynsign-design-language.md`](../design/zynsign-design-language.md).

## Release map

| Stage | Tag | Switches on |
|---|---|---|
| Professional | `v2.0.0` | Depth and fixes across the 1.0 surface; no new `ReleaseFeature` |
| RC 2 | `v1.0.0-rc.2` | **Smart Workspace** home — the 1.0 Mission Control |
| Nova preview | `v3.0.0-nova.1` | **Nova Assistant** |
| Nova | `v3.0.0` | The areas below as each lands (one `ReleaseFeature` each, added to the train when its code is complete) |

## Area map — where each feature lives

Legend: ✅ exists · 🔧 upgrade of existing code · 🆕 new · 📐 scaffolded in this tree

### A. Smart Workspace — flagship 📐 (ships in 1.0)

The command center Home becomes once `smartWorkspace` is on: greeting, Continue Last Session, Quick Sign, Install Health, Recent Apps, Certificate Health, Download Queue.

| Piece | Layer | File | State |
|---|---|---|---|
| Widget vocabulary, usage signal, day-part, layout policy | Domain | `Domain/Nova/WorkspaceWidget.swift` | 📐 done |
| Last-session record | Domain | `Domain/Nova/WorkspaceSession.swift` | 📐 done |
| `WorkspaceStateStore` port, `SmartWorkspaceService`, snapshot | Application | `Application/Nova/SmartWorkspace.swift` | 📐 done |
| File-backed state (usage + session) | Platform | `Platform/FileWorkspaceStateStore.swift` | 📐 done |
| Dashboard, cards, Nova card | Presentation | `Presentation/Nova/SmartWorkspaceView.swift` | 📐 done (first pass) |
| Composition | App | `CompositionRoot` → `environment.smartWorkspace` | 📐 done |

Widgets: Continue Last Session · Health Score · Recent Apps · Signing Queue ·
Downloads · Identity Health · Profile Expiry · Backup · Collections · Activity.
Order = live work → time of day (morning: continue; night: back up) → usage
with a 7-day half-life → default. The policy never hides a widget; the view
gates each on the train and on data.

Next: Active-queue and download counts fed from `SigningQueue` /
`DownloadCenter`; backup age from the Recovery store; iPad two-column layout.

### B. Nova Assistant 📐

| Piece | Layer | File | State |
|---|---|---|---|
| `NovaFacts`, `NovaRecommendation`, `NovaAdvisor` rules | Domain | `Domain/Nova/NovaRecommendation.swift` | 📐 done |
| Fact collection from existing stores | Application | `SmartWorkspaceService.collectFacts` | 📐 done |
| Card with Open / Dismiss | Presentation | `SmartWorkspaceView` | 📐 done |

Rules today: certificate/profile expiring or expired · matching profile
exists · no profile covers app · previously signed app · duplicate bundle ·
backup recommended · first-step nudges. Next: “better certificate” (reuse
`SigningIdentityRecommendation`), “faster preset” (reuse `SigningPresetWorkflow`
matching), “source recommendation” (reuse repository health).

**Not autonomous, by construction:** the advisor returns values; the view has
no code path that mutates a store.

### C. Install Health Pro 📐

| Piece | Layer | File | State |
|---|---|---|---|
| Checks, weights, score, verdict | Domain | `Domain/Nova/InstallHealthReport.swift` | 📐 done |
| Check runners (certificate, profile, conflict, entitlements, framework, signature, device, history) | Application | new `InstallHealthAssessment` use case over `SigningHealthScore`, `ProfileCompatibilityEngine`, `IPABinaryInspection`, installed-apps store | 🔧 next |
| Score ring + checklist in App Studio and the workspace | Presentation | | 🆕 next |

`notPerformed` earns nothing and blocks *Ready*; a failed gating check
(certificate, profile, signature) is *Blocked*.

### D. App DNA 2.0 / P. App Studio 🔧

Each app gets a passport page: Overview · Metadata · Signature · Resources ·
History · Notes · Install Health. Upgrades `ApplicationDetailView` with a
timeline (Imported → Analyzed → Signed → Verified → Delivered) assembled
from `ApplicationRecord`, `SigningRecord`, and installation history.
Domain: `ApplicationTimeline` (new, pure). No new stores.

### E. Binary Studio 🔧

Mach-O Explorer, framework graph, segment viewer, symbol summary, hash
verification, resource preview — extends `BinaryInspectorView` and
`ResourceStudio` over `IPABinaryInspection`. Domain additions: `FrameworkGraph`
(dependency edges from load commands; reuses `NestedCodeSigning` ordering).

### F. Repository Hub 🔧

Explore (Trending · Recently Updated · Staff Picks · Categories), offline
browse over `FileStoreCache`, source trust (update frequency, metadata
quality, signature consistency) computed by a pure `SourceTrustPolicy` over
existing repository-health facts. No new network paths.

### G. Smart Collections+ 🔧

Rule-based automatic membership (`CollectionRule`: category, source,
team, bundle prefix) evaluated in `LibraryOrganizer`. Existing smart
collections gain rules; no new store.

### H. Project Workspaces 🆕

Isolated environments (Gaming · Development · Testing · Enterprise) each
scoping apps, identities, profiles, notes, history. Domain: `ProjectWorkspace`
+ `WorkspaceScope`; Application: a scope filter applied by every listing use
case; Platform: one document beside the library catalog. Identities remain in
the one Keychain — a workspace is a *view*, never a second key store.

### I. Signing Queue Pro 🔧

Concurrent workflows, pause/resume/reorder/retry — extends `SigningQueue`
and its Live Activity. Domain: `SigningQueuePolicy` (concurrency limit,
priority, retry budget).

### J. Living UI System · K. Dynamic Island & Live Activities 🔧

Ribbon motion for splash, progress, success, install-complete, empty states,
onboarding; Live Activities for signing, downloading, verification. Lives in
`Presentation/DesignSystem` (tokens, `ZRibbon` shapes) and the existing
`ActivityKit` platform adapter. Every animation has a Reduce Motion path.

### L. Backup Center Pro 🔧

Automatic snapshots, restore preview, history, size estimation, workspace
restore — over the Recovery store. Domain: `BackupSchedule`, `RestorePlan`.

### M. Trust Center 🆕

One dashboard reading the Identity Center, profile validity, source trust,
backup state, and the local security-event journal. Read-only composition;
no new secrets.

### N. Developer Console 🔧

Hidden advanced page: build and signing logs, verification reports,
diagnostics export, performance stats — composes `SigningDiagnosticsService`,
`ExternalValidationExport`, and the Performance Engine.

### O. Premium Personalization 🆕

Alternate icons (Crystal · Midnight · Blueprint · Frost · Aurora) rendered
from the same master by `Scripts/generate_brand_assets.py`; accent themes
(Purple · Blue · Silver) as design tokens. Subtle only.

### Q. Universal Spotlight 🔧

One search over apps, identities, profiles, sources, notes, collections,
workspaces — extends `SearchIndex`. Optional Core Spotlight donation stays
on-device.

### R. Smart Notifications 🔧

Only: certificate expires tomorrow · download complete · backup finished ·
install health changed. Reuses `SigningQueueNotifying` / `DownloadNotifying`;
gated by the notification preference.

### S. Hidden premium details

| Action | Haptic | Where |
|---|---|---|
| Import | light | `ZHaptics.tap()` |
| Sign | medium | `ZHaptics.impact(.medium)` |
| Success | success | `ZHaptics.success()` |
| Error | error | `ZHaptics.error()` |

Custom empty-state illustrations (No Apps · No Certificates · No Downloads ·
No Sources) drawn from the Z·Pen geometry — no stock artwork.

## Design evolution

| Version | Theme |
|---|---|
| 0.1 | Foundation |
| Alpha | Core experience |
| Beta | Stability |
| RC | Polish |
| 1.0 | First public |
| 2.0 | Professional platform |
| **3.0 Nova** | **Complete iOS signing platform** |

## How a Nova feature lands

1. Domain types and policy, with tests in `Tests/ZynSignTests/NovaTests.swift`.
2. Application use case over existing ports; a new port only when a new
   document is genuinely needed.
3. Platform adapter (usually one JSON document beside the library catalog).
4. Presentation through `DesignSystem` only; the mark through `ZynSignMark`.
5. One `ReleaseFeature` case with prerequisites, introduced in `.nova`;
   `python3 Scripts/release_train.py check` and `ReleaseTrainTests` stay green.
6. Docs: this page's row moves from 🆕/🔧 to 📐, the changelog gets a line,
   and [`WHAT_DOES_NOT_EXIST.md`](WHAT_DOES_NOT_EXIST.md) is re-read to make
   sure no screen now implies a *never*.
