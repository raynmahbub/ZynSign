# Design System Audit

**Scope:** `ZynSign/Presentation/` (every call site outside `DesignSystem/`).
**Method:** `python3 Scripts/audit_design_tokens.py` — the same script now
guards the counts in CI against `Scripts/design_tokens_baseline.json`.
**Date:** 2026-09-28.

## Before

| Category | Call sites | Notes |
|---|---|---|
| Hard-coded colours | **0** | Already clean — `audit_accessibility.py --strict` has enforced this since RC 1 |
| Inline shadows | **0** | `zynSoftShadow(_:)` is the only path |
| Feedback generators outside `ZHaptics` | **0** | Already centralised; `ZHaptics.play(_:)` added the vocabulary |
| Inline animation durations / springs | **82** (36 with a literal duration) in 21 files | `.snappy` ×22, `.spring(response: 0.35, dampingFraction: 0.8)` ×8, `.easeInOut(0.2)` ×12, `.easeInOut(0.15)` ×5, `.smooth(0.22)` ×4, `.snappy(0.2…0.28)` ×7, others; plus a second, unused motion token set (`ZynSignTokens.Motion` / `ZAnimation`, 0 uses) beside `ZMotion` |
| Literal corner radii | **19** in 10 files | 8 of them app-icon artwork radii proportional to the icon size (36→9, 40→10, 48→12, 56→13, 64→16, 72→17, 80→18, 100→24 — the iOS icon ratio, spelled by hand each time) |
| Fixed font sizes | **11** in 10 files | Hero numerals (34–56 pt) and two graph labels (9–10 pt) |
| Off-grid spacing literals | **41** in 22 files | 30 of them `spacing: 3` (tight metadata stacks); the rest divider insets (60/68/120) and single one-offs (5, 7, 18, 22, 26) |
| Duplicated skeleton rows | 1 | `LibrarySkeletonRow` beside `ZSkeletonAppRow` (kept: the library's is static on purpose — no shimmer per row) |
| Duplicated dashboard card frame | 1 | `WorkspaceCard` / `WorkspaceLinkRow` private to the Smart Workspace |

## Replacements made

| Was | Now | Sites |
|---|---|---|
| `.snappy`, `.snappy(duration: ≤0.25)`, `.smooth(0.22)`, `.easeInOut(0.15/0.2)`, `.easeOut(0.15)` | `ZMotion.fast` (200 ms ease-out) | 58 |
| `.snappy(duration: 0.28)`, `.easeInOut(0.3)` | `ZMotion.standard` (300 ms ease-in-out) | 2 |
| `.spring(response: 0.3–0.35, …)`, `.spring()` | `ZMotion.interactive` | 14 |
| `.spring(response: 0.4, dampingFraction: 0.85)` | `ZMotion.relaxed` (450 ms spring) | 1 |
| `reduceMotion ? nil : <curve>` | the preset (already `nil` under Reduce Motion **and** the in-app preference) | 12, and four now-unused `@Environment(\.accessibilityReduceMotion)` removed |
| `ZynSignTokens.Motion` / `ZAnimation` | deleted (0 uses) | — |
| Icon artwork `cornerRadius: <n>` | `ZRadius.appIcon(side:)` | 9 |
| `cornerRadius: 12 / 16 / 3` | `ZRadius.card / .lg / .xs` | 6 |
| Skeleton shimmer `repeatForever` unconditionally | gated on `ZMotion.permitsAnimationGlobally` | 4 |
| `WorkspaceCard`, `WorkspaceLinkRow`, header, Quick Sign row, Install Health block, identity/profile rows | `ZDashboardCard`, `ZDashboardLinkRow`, `GreetingCard`, `QuickActionCard`, `HealthCard`, `IdentityCard`, `DownloadCard`, `RecentListCard` in `DesignSystem/Components/ZDashboardCards.swift` | 1 screen, 8 reusable parts |
| `Font.system(size: 34)` in the health score | `.system(.largeTitle, design: .rounded)` (34 pt, scales with Dynamic Type) | 1 |

## Deliberately left

* `spacing: 3` (×30) — a real value in tight metadata stacks; adding a
  3 pt token would legitimise it everywhere. Candidate for `ZSpacing.xxs`
  (4) in a screen-by-screen pass with screenshots, not in a mechanical one.
* Hero numerals at 44–56 pt (certificate / profile / queue detail heroes) —
  moving them to text styles changes their size; needs a visual pass.
* `cornerRadius: 20` (store card), `9` and `6` (chips) — one-offs whose
  nearest token differs by ≥ 2 pt; changing them would be a redesign.
* `.borderedProminent` (×34) — the system button is the correct default;
  `ZPrimaryButtonStyle` is for hero CTAs only.
* `.linear(duration: 0.2)` on a progress bar — progress must not ease; kept,
  gated on the same policy.

## After

| Category | Call sites | Distinct values | Files |
|---|---|---|---|
| colour | 0 | — | 0 |
| radius | 3 | 6, 9, 20 | 3 |
| spacing | 40 | 3, 5, 7, 18, 22, 26, 60, 68, 120 | 21 |
| font | 10 | 9, 10, 13, 14, 34, 36, 44, 52, 56 | 9 |
| shadow | 0 | — | 0 |
| motion | 1 | 0.2 | 1 |
| haptics | 0 | — | 0 |

### radius (3)

- `ZynSign/Presentation/ApplicationDetailView.swift` — 1: L1485 (9)
- `ZynSign/Presentation/IdentityCenter/IdentityRelationshipGraphView.swift` — 1: L262 (6)
- `ZynSign/Presentation/Store/StoreComponents.swift` — 1: L58 (20)

### spacing (40)

- `ZynSign/Presentation/ApplicationDetailView.swift` — 14: L1136 (3), L1153 (3), L1164 (3), L1335 (3), L1415 (3), L1458 (3), L1487 (3), L1527 (7) …
- `ZynSign/Presentation/ApplicationLibraryView.swift` — 4: L1104 (3), L1259 (3), L1431 (60), L1432 (120)
- `ZynSign/Presentation/BinaryInspectorComponents.swift` — 2: L85 (3), L193 (3)
- `ZynSign/Presentation/BinarySignatureViews.swift` — 2: L300 (3), L663 (3)
- `ZynSign/Presentation/Store/StoreDiscoveryViews.swift` — 2: L38 (5), L122 (3)
- `ZynSign/Presentation/AppStoreView.swift` — 1: L122 (22)
- `ZynSign/Presentation/BinaryComparisonView.swift` — 1: L213 (3)
- `ZynSign/Presentation/BinaryStructureViews.swift` — 1: L163 (3)
- `ZynSign/Presentation/DuplicateResolutionCenterView.swift` — 1: L260 (3)
- `ZynSign/Presentation/EntitlementsStudioView.swift` — 1: L178 (5)
- `ZynSign/Presentation/HomeView.swift` — 1: L305 (68)
- `ZynSign/Presentation/IdentityCenter/IdentityRelationshipGraphView.swift` — 1: L260 (5)
- `ZynSign/Presentation/ImportHubComponents.swift` — 1: L319 (3)
- `ZynSign/Presentation/InstallationWorkspaceComponents.swift` — 1: L138 (3)
- `ZynSign/Presentation/ResourceStudio/DuplicateResourcesView.swift` — 1: L56 (3)
- `ZynSign/Presentation/ResourceStudio/ImageGalleryView.swift` — 1: L74 (5)
- `ZynSign/Presentation/ResourceStudio/LaunchScreenStudioView.swift` — 1: L45 (3)
- `ZynSign/Presentation/ResourceStudio/ResourceStudioView.swift` — 1: L128 (7)
- `ZynSign/Presentation/Settings/AppLockOverlay.swift` — 1: L26 (7)
- `ZynSign/Presentation/SigningQueueView.swift` — 1: L724 (3)
- `ZynSign/Presentation/Store/StoreComponents.swift` — 1: L33 (5)

### font (10)

- `ZynSign/Presentation/IdentityCenter/IdentityRelationshipGraphView.swift` — 2: L252 (9), L255 (10)
- `ZynSign/Presentation/CertificateDetailsView.swift` — 1: L424 (56)
- `ZynSign/Presentation/ImportDropTarget.swift` — 1: L154 (44)
- `ZynSign/Presentation/InstallationRelationshipView.swift` — 1: L73 (13)
- `ZynSign/Presentation/ProfilesView.swift` — 1: L599 (52)
- `ZynSign/Presentation/ResourceStudio/ResourceStudioComponents.swift` — 1: L284 (34)
- `ZynSign/Presentation/ResourceStudio/VideoExplorerView.swift` — 1: L68 (36)
- `ZynSign/Presentation/Settings/AppLockOverlay.swift` — 1: L24 (14)
- `ZynSign/Presentation/SigningQueueConfigurationView.swift` — 1: L388 (52)

### motion (1)

- `ZynSign/Presentation/ImportHubComponents.swift` — 1: L125 (0.2)



The baseline (`Scripts/design_tokens_baseline.json`) is these numbers; CI
fails if any category grows.
