<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Design Documentation

The design system of record for ZynSign. One language, one source of truth:
[ZynSign Design Language (ZDL) v1.0](zynsign-design-language.md).

## The rule

If a value is not in `ZynSignTokens`, it does not ship. No screen introduces a
radius, spacing step, animation, or colour that the tokens and ZDL do not
define — a change to the look is a change to ZDL first.

| Source | Location |
|---|---|
| Tokens — spacing, radius, shadow, colour, type | `ZynSign/Presentation/DesignSystem/DesignTokens.swift` (`ZSpacing` / `ZRadius` / `ZShadow` / `ZColors` / `ZTypography`, `ZHaptics`) |
| Motion — four presets, one Reduce Motion policy | `ZynSign/Presentation/DesignSystem/ZMotion.swift` (`ZMotion.fast / standard / interactive / relaxed`) |
| Guard — hand-written values may not grow | `python3 Scripts/audit_design_tokens.py --baseline Scripts/design_tokens_baseline.json --check` (CI) · [audit record](../internal/DesignSystemAudit.md) |
| Components | `ZynSign/Presentation/DesignSystem/Components/` |
| Specification | [zynsign-design-language.md](zynsign-design-language.md) |
| Brand book — logo, colours, type, motion & haptics, asset usage | [brand/](brand/README.md) |

## Components at a glance

| Component | Purpose |
|---|---|
| `ZCard` | Material, filled, and outlined card containers with dark-mode edge definition |
| `ZDashboardCard` · `ZDashboardLinkRow` · `GreetingCard` · `QuickActionCard` · `HealthCard` · `IdentityCard` · `DownloadCard` · `RecentListCard` | The dashboard building blocks (Smart Workspace, future Trust Center); plain values in, one accessibility element out |
| `ZEmptyIllustration` | Four vector line-art drawings in the Z·Pen language for the empty states |
| `ZButtonStyles` | Primary / secondary / destructive / large-prominent styles; ≥ 44×44 pt targets; spring press |
| `ZStatusBadge` | Semantic status pill — colour means the state, never decoration |
| `ZProgressRing` | Determinate progress for signing and verification runs |
| `ZSigningStageList` | The nine pipeline stages as the run presents them |
| `ZSkeleton` | Shimmer placeholders for rows and grids — loading is never a blank screen |
| `ZEmptyState` | Layered, human empty states with one clear action |
| `ZErrorView` | What happened · why · **what to do next** · expandable technical detail |
| `ZToast` | Transient results with success / warning semantics |
| `ZBottomSheet` | Detents and dismissal for auxiliary flows |
| `ZOnboardingView` | The six-step first-launch walkthrough |

## Tokens in one table

| Category | Scale |
|---|---|
| Spacing | 4 pt grid — `xxs 4 · xs 8 · sm 12 · md 16 · lg 20 · xl 24 · xxl 32 · xxxl 48` |
| Radius | `xs 4 · sm 8 · card 12 · icon 14 · lg 16 · xl 24 · pill` |
| Shadow | `subtle · soft · card · elevated` — calibrated per light and dark mode |
| Colour | Semantic system colours (`success` / `warning` / `error` / `info`) + `accentColor`; adaptive, high-contrast aware |
| Type | Dynamic Type throughout; `cardTitle .headline`, `code` monospaced subheadline |
| Motion | One spring per interaction — `standard 0.35/0.8`, `snappy 0.25/0.75`, `gentle 0.3`, `cardExpand 0.4/0.82` |

Full tables with usage: ZDL §2–§3.

## Visual language

- SF Symbols everywhere; weights follow the text they accompany.
- Materials over flat fills for headers; cards float on `ZShadow`.
- Every state is designed: loading (`ZSkeleton`), empty (`ZEmptyState`), error
  (`ZErrorView`) are components, not afterthoughts.
- Dark mode is a first-class target — cards carry a `primary @ 6 %` edge stroke
  so boundaries survive OLED black.

## Repository brand assets

Marketing-facing visuals (README banner, social preview, logo, favicon) are
not part of the app, but obey the same discipline — one geometry, one palette:

`Assets/Brand/` — see [Assets/README.md](../../Assets/README.md).
