# Colors

Two numbers define the brand; everything else is a neutral or a system
semantic colour. The same values live in
`Presentation/DesignSystem/Brand/ZynSignMark.swift` (`ZynBrand`) and
`Scripts/generate_brand_assets.py`; change one, change both.

## Brand

| Token | Light | Dark | Use |
|---|---|---|---|
| `indigoTop` → `indigoBottom` | `#6D6AF0` → `#4B48C4` | `#7C79F5` → `#5A57D6` | The tile gradient (top-left → bottom-right), accent, prominent buttons, links |
| Icon dark ground | — | `#1E1C34` → `#0C0C14` | Dark-appearance app icon only |

## Neutrals

| Token | Value | Use |
|---|---|---|
| `ink` | `#1D1D1F` | Wordmark and headlines on light |
| `paper` | `#F5F5F7` | Wordmark and headlines on dark; light page ground |
| `surfaceDark` | `#15151D` | Dark banners, social preview, hero |
| `mutedLight` / `mutedDark` | `#6E6E73` / `#A1A1AA` | Secondary copy |

In the app itself, backgrounds and text use **system semantic colours**
(`Color(.systemBackground)`, `.primary`, `.secondary`), so Increase Contrast,
Reduce Transparency and Smart Invert behave exactly as they do in Apple's apps.

## Status colours — never colour alone

| Meaning | Colour | Always paired with |
|---|---|---|
| Passed / healthy | system green | `checkmark.circle.fill` |
| Warning / expiring | system orange | `exclamationmark.triangle.fill` |
| Failed / blocked | system red | `xmark.octagon.fill` |
| Not performed | secondary | `circle.dashed` |
| Informational | indigo | `lightbulb.fill` |

Every status is a symbol **and** a colour **and** a word, so the meaning
survives deuteranopia, grayscale and VoiceOver.

## Contrast

* White mark on `indigoBottom`: 6.9 : 1. White on `indigoTop`: 4.2 : 1 — AA
  for large text only, which is why text on the tile is never smaller than
  17 pt semibold and the gradient runs darker under any label.
* `ink` on `paper`: 15.5 : 1. `paper` on `surfaceDark`: 16.7 : 1.
* `mutedLight` on `paper`: 4.7 : 1 (AA); `mutedDark` on `surfaceDark`: 7.1 : 1.

## Accent themes (roadmap)

Purple (default), Blue (`#3A7BF5` → `#2455C4`), Silver (`#9A9AA6` → `#6B6B78`)
are planned as token sets that swap `indigoTop/Bottom` only — the neutrals,
status colours and mark never change.
