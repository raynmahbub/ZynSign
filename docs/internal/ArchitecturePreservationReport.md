# Architecture Preservation Report — Design System Foundation

## Summary

**Objective.** One reusable design foundation, no behaviour change, no
architectural change. The repository already had a token system
(`ZynSignTokens` → `ZSpacing / ZRadius / ZShadow / ZColors / ZTypography`),
a component library (`Presentation/DesignSystem/Components`), an
environment-aware motion type (`ZMotion`) and a stateless haptics helper
(`ZHaptics`). Per the milestone's own rule — *extend or normalise what
exists rather than introduce a parallel system* — no `ZynSignDesignSystem/`
module and no `ZS*`-prefixed duplicates were created. The existing
`DesignSystem` folder **is** the design system; this pass made it the only
one.

### Modules touched

| Layer | Touched | Nature |
|---|---|---|
| Presentation / DesignSystem | `DesignTokens.swift`, `ZMotion.swift`, `Components/ZSkeleton.swift`, **new** `Components/ZDashboardCards.swift`, `Components/ZEmptyIllustration.swift` (this milestone series), `Components/ZEmptyState.swift` | tokens and components |
| Presentation / screens | 25 files | mechanical: animation literals → `ZMotion` presets; icon radii → `ZRadius.appIcon(side:)`; four unused `reduceMotion` environment reads removed |
| Presentation / `RootView` | 1 | publishes the resolved motion policy to `ZMotion.permitsAnimationGlobally` next to the existing environment value |
| Presentation / Nova | `SmartWorkspaceView.swift` | rewritten as a Domain→component mapping over the shared cards; identical output |
| Application, Domain, Platform, App | **0 files** | — |
| Scripts / CI | `audit_design_tokens.py` (new), `design_tokens_baseline.json` (new), `generate_brand_assets.py` (GIF check tolerance), `ci.yml` (+1 step) | guard |
| Assets | `Brand/Motion/` (hero moved from `Social/`), `Assets/README.md` | organisation |
| Docs | `design/README.md`, `design/zynsign-design-language.md` §3, `design/brand/Motion.md`, `internal/*`, `CHANGELOG.md` | accuracy |

### Public API changes

Everything is `internal` to the app target; there is no framework API.
Within the target:

| Symbol | Change | Callers |
|---|---|---|
| `ZynSignTokens.Motion`, `typealias ZAnimation` | **removed** | 0 |
| `ZMotion.fast / standard / interactive / relaxed` | added (instance and static) | new call sites |
| `ZMotion.quick / arrive / hero` | kept as aliases | unchanged |
| `ZMotion.Curve` | added — the four `Animation` constants | `ZMotion` only |
| `ZMotion.permitsAnimationGlobally` | added | `RootView` (set), presets and `ZSkeleton` (read) |
| `ZRadius.appIcon(side:)` | added | 9 artwork call sites |
| `ZDashboardCard`, `ZDashboardLinkRow`, `GreetingCard`, `QuickActionCard`, `HealthCard`, `IdentityCard`, `DownloadCard`, `RecentListCard` | added | `SmartWorkspaceView` |
| `ZHaptics.Moment`, `ZHaptics.play(_:)` | added (previous commit in this series) | Smart Workspace, `SigningView` |

**Breaking changes: none.**

## Behavioural deltas (intentional, all sub-perceptual or accessibility-positive)

1. Animation timings collapsed to four presets: the 150/220/250/280 ms
   variants now run at 200 or 300 ms; three spring damping variants
   (0.75–0.9) now use 0.80. Largest single change: 80 ms.
2. Twelve animations that previously honoured only the system Reduce
   Motion switch now also honour the in-app animation preference
   ("Reduced" / "Off"), because the presets resolve both.
3. Skeleton shimmer no longer loops under Reduce Motion or with animation
   off. Previously it ran regardless (a `repeatForever` timer on every
   visible placeholder).
4. Icon artwork corners in the Store and Downloads now use the exact iOS
   ratio; the largest change from the hand-written values is 1 pt
   (48 pt icon: 10 → 11). Skeleton bar radius 3 → 4 pt.
5. Install Health score numeral: fixed 34 pt → `largeTitle` rounded (34 pt
   at the default size, now scales with Dynamic Type).

Nothing else on screen changed: the same strings, the same layout, the
same navigation, the same data sources.

## Risk assessment

| Area | Risk | Reasoning |
|---|---|---|
| Performance | **Lower than before** | Fewer perpetual animations; static presets are constant lookups behind an `NSLock`, read once per animation, not per frame. No new observation, no new work on the main actor. |
| UI | **Low** | Mechanical substitutions verified by `git diff` review and by the token audit's before/after counts (motion 82 → 1, radius 19 → 3). The Smart Workspace rewrite renders the same rows from the same values. |
| Accessibility | **Improved** | Reduce Motion coverage widened; decorative loops stopped; new components combine into one element with header traits and `≥ 44 pt` targets. |
| Concurrency | Low | `permitsAnimationGlobally` mirrors the existing `ZHaptics.isEnabled` pattern (lock-guarded static). Written from `RootView.body` on the main actor. |
| Rollback scope | One commit | Revert restores the literals; no data format, store or schema was touched. |

## Verification

| Gate | Result |
|---|---|
| `python3 Scripts/release_train.py check` | ✓ |
| `python3 Scripts/audit_crash_surface.py` | ✓ baseline unchanged (5) |
| `python3 Scripts/audit_accessibility.py --strict` | ✓ |
| `python3 Scripts/audit_regression_coverage.py` | ✓ |
| `python3 Scripts/audit_design_tokens.py --baseline … --check` | ✓ (new gate; baseline = post-pass counts) |
| `python3 Scripts/generate_brand_assets.py --check` | ✓ |
| `python3 Scripts/update_readme.py --check` | ✓ |
| Host vectors (`Tests/Host/*.py`) | ✓ |
| Xcode build + `ZynSignTests` | **Not run in this environment** — no Swift toolchain in the sandbox. Static review only. Run ⌘U before merging; the files most worth a look are `ZMotion.swift` (static/instance members sharing names), `ZDashboardCards.swift` (generic `RecentListCard`), and `SmartWorkspaceView.swift`. |
| Manual verification | Not possible here. Suggested 10-minute pass: Library scroll with Reduce Motion on/off; Settings → Animations → Off, then reorder the signing queue; Smart Workspace cards with VoiceOver; Store list icons. |

## What this milestone did not do (and why)

* No `ZSButton` / `ZSBadge` / `ZSSection` / `ZSDivider`: `ZButtonStyles`,
  `ZStatusBadge`, SwiftUI `Section` and `Divider` already fill those roles;
  a second name for each is the parallel system the brief forbids.
* No replacement of `.borderedProminent` (34 sites) — the system style is
  the intended default on iOS; `ZPrimaryButtonStyle` is for hero CTAs.
* No `spacing: 3` → token sweep (30 sites) and no hero-numeral font pass
  (10 sites): both change what the user sees and belong in a screenshot-
  reviewed pass. They are listed in the audit as the remaining backlog.
* No wallpapers folder: no consumer for it yet; the generator can add one in
  minutes when the website needs it.
