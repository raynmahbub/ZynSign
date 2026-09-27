# ZynSign Design Language (ZDL) v1.0 — Genesis

This is the permanent specification for ZynSign from `0.1.0-dev` through `1.0.0`. It locks tokens, motion, and component behavior so every screen feels like it came from the same product. No screen after `0.1.0-dev` should introduce a new radius, spacing, or animation without updating this document.

ZynSign is a scratch project; ZDL is ZynSign’s own language, not a copy of any other app. Values are chosen for ZynSign’s own signing/library/certificate experience.

## 1. Principles

* **Material, not flat.** Cards float on soft shadows; headers use `.ultraThinMaterial`.
* **One truth.** Never hardcode `12` or `16`. Use `ZSpacing`/`ZRadius`.
* **Deterministic motion.** Every interaction has exactly one spring, one haptic, one duration.
* **Honest states.** Loading, empty, and error are first-class components (`ZSkeleton`, `ZEmptyState`), never blank space.

## 2. Tokens — `DesignTokens.swift` is the source of truth

| Category | Token | Value | Usage |
|---|---|---|---|
| Spacing | `ZSpacing.xxs` | 4 | Icon-to-label |
| | `xs` | 8 | Tight groups |
| | `sm` | 12 | Card inner |
| | `md` | 16 | Screen padding |
| | `lg` | 20 | Section gaps (Home) |
| | `xl` | 24 | Featured carousel |
| | `xxl` | 32 | Hero |
| Radius | `ZRadius.sm` | 8 | Pills, badges |
| | `card` | 12 | Cards, rows |
| | `icon` | 14 | Icon wells |
| | `lg` | 16 | Headers, large cards |
| | `xl` | 24 | Featured |
| Shadow | `ZShadow.soft` | 0.06/8/4 | General elevation |
| | `card` | 0.08/12/6 | Cards on scroll |
| Colors | `ZColors.primary` | `accentColor` | Accent |
| | `cardBackground` | `secondarySystemBackground` | Cards |
| | `headerMaterial` | `.ultraThinMaterial` | Headers |
| Success/Warning/Error | via `ZStatusBadge` | green/orange/red | Status pill |

Typography: `ZynSignTokens.Typography` — `cardTitle .headline`, `footnoteSecondary .footnote`, `captionSecondary .caption`. Change there, not in views.

## 3. Animation & Haptics

Motion is `ZMotion` — one policy (system Reduce Motion + the in-app
animation preference) resolved in `RootView` and read either from the
environment (`@Environment(\.zMotion)`) or statically (`ZMotion.fast`), both
returning `nil` when animation is off. Call sites never write a duration.

| Preset | Curve | Use |
|---|---|---|
| `fast` | ease-out 200 ms | Content replacing content, a row toggling, a chip, list reorders |
| `standard` | ease-in-out 300 ms | A state change the user caused |
| `interactive` | spring 350 ms / 0.80 | Things that follow a finger or settle after a tap; toasts |
| `relaxed` | spring 450 ms / 0.82 | The ribbon drawing itself, a success tick, a ring filling |
| `fade` | opacity transition | Rows appearing in a list — never an offset per row |

Haptics are `ZHaptics.play(_:)`: `imported` light · `select` selection ·
`sign` medium · `succeeded` success · `attention` warning · `failed` error ·
`navigate` light. `ZHaptics` is stateless; never retain a generator. Details
and the reasoning: [brand/Motion.md](brand/Motion.md).

## 4. Components — `Presentation/DesignSystem/Components/`

All components are **pure UI**, never business logic. They accept content via closures and style only via tokens.

| Component | File | Purpose |
|---|---|---|
| `ZCard` | `ZCard.swift` | Material/card container. Replaces `background(Color(...), in: RoundedRectangle(cornerRadius: 12))`. Variants: `.material`, `.filled`, `.outlined` |
| `ZStatusBadge` | `ZStatusBadge.swift` | Pill for `Verified / Expired / Matched / Mismatch`. Color is semantic, not decorative. |
| `ZSkeleton` | `ZSkeleton.swift` | Shimmer placeholder for loading rows. Replaces `ProgressView` spins in lists. |
| `ZEmptyState` | (use `ContentUnavailableView` + `ZCard`) | Empty/error — always icon + title + honest description + action |
| `ZToast` | (future) | Slide-in banner for import success/failure |
| `ZProgressRing` | (future) | Circular progress for signing stages |

Contracts:

* `ZCard` adds `padding(ZSpacing.md)` and `zynSoftShadow` internally — caller does not add its own shadow.
* `ZStatusBadge` never shows more than 2 badges per row; overflow goes to detail.
* `ZSkeleton` animates only when `isLoading`; otherwise it is `EmptyView`.

## 5. Screen Rules

**Home** — Header `ZCard.material` (`Radius.lg`), Quick Actions `HStack(spacing: ZSpacing.sm)` with `ZCard.filled`, Library summary `ZCard.filled` (`Radius.lg`). No custom radii.

**Library** — Rows are `ZCard.filled` only in detail; list rows stay `List` but use `ZStatusBadge` for `availabilityText`. Empty states via `ContentUnavailableView` inside `ZCard`.

**Certificates** — Row shows `ZStatusBadge` for `isUsableForSigning` (green `Ready` / orange `Needs Attention`), plus `ZStatusBadge` for association. Detail uses `ZCard` sections.

**Signing** — Status machine `Idle → Preparing → Analyzing → Signing → Verifying → Completed` is a `ZProgressRing` + `ZStatusBadge` sequence, never ad-hoc text.

## 6. Accessibility

* All interactive elements minimum 44pt hit target.
* Dynamic Type: tokens use `Font` styles, not fixed sizes.
* VoiceOver: badges have `accessibilityLabel`.

## 7. Change Process

Before adding a new radius/spacing/color, update `DesignTokens.swift` **and** this document in the same commit. No view should introduce a literal `14` or `0.06` outside tokens.

---

*Genesis lock: `0.1.0-dev` f2b4473. Future releases `0.1.x-dev → alpha → beta → RC → 1.0.0` sit on this language; major visual refactor before `1.0` is a failure of this spec.*
