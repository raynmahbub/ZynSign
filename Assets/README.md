<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Brand/Logo/logo-lockup-dark.svg">
    <img src="Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Assets

The ZynSign brand system. One master artwork, one script, every derived asset.

```
Assets/Brand/
├ Source/     zpen-mark-1024.png  ← the master (white Z·Pen on transparent)
│             zpen-mark.svg       ← the same mark traced as a vector path
├ AppIcon/    app-icon.svg · app-icon-{,dark-,tinted-}1024.png (reference copies)
├ Logo/       logo-mark{,-dark}.svg · logo-mark{,-dark}-{128,256,512}.png · logo-lockup{,-dark}.svg
│             logo-monochrome{,-white}.svg · logo-outline{,-white}.svg · wordmark{,-dark}.svg
├ AppIcon/Alternates/  Crystal · Midnight · Blueprint · Frost · Aurora (1024², full-bleed)
├ Banner/     banner-{light,dark}.svg              docs header / social
├ Motion/     hero.gif · hero-still.png            README hero (the living logo)
├ Favicon/    favicon.svg · favicon-{16,32,48}.png · favicon.ico · apple-touch-icon.png · android-chrome-{192,512}.png · site.webmanifest
└ Social/     social-preview.png (dark) · social-preview-light.png · github-avatar.png
```

Usage rules per surface: [`docs/design/brand/Asset-Usage.md`](../docs/design/brand/Asset-Usage.md).

The shipping app icon lives in the Xcode asset catalog
(`ZynSign/Resources/Assets.xcassets/AppIcon.appiconset`) together with the
`PenMark` image set that the SwiftUI `ZynSignMark` view draws. Both are
generated from the same master.

## The mark

A bold white **Z** whose diagonal is a fountain pen — barrel, collar, nib — with
a signature swash beneath, on an indigo **Liquid Glass** tile.

| Token | Value |
|---|---|
| Tile gradient (light) | `#6D6AF0 → #4B48C4`, top-left → bottom-right |
| Tile gradient (dark surfaces) | `#7C79F5 → #5A57D6` |
| Corner | continuous curve, 22.37 % of the side (the iOS icon shape) |
| Glyph | 66 % of the tile height, optically centred |
| Ink / paper / dark surface | `#1D1D1F` / `#F5F5F7` / `#15151D` |

## iOS app icon

Three 1024 × 1024 appearances, exactly as Xcode 16 expects:

| Appearance | File | Treatment |
|---|---|---|
| Light (default) | `AppIcon-1024.png` | Opaque, full-bleed gradient — no baked-in corners or borders; iOS applies the mask |
| Dark | `AppIcon-dark-1024.png` | Deep indigo-black ground with a soft indigo halo, white glyph |
| Tinted | `AppIcon-tinted-1024.png` | Grayscale glyph on transparent — the system supplies the tint and background |

## Regenerating

```sh
pip install pillow numpy opencv-python-headless   # opencv is only used to trace the SVG path
python3 Scripts/generate_brand_assets.py           # writes every derived asset
python3 Scripts/generate_brand_assets.py --check   # reports anything that drifted from the master
```

Rules:

- **Edit only the master.** Change `Brand/Source/zpen-mark-1024.png`, re-run the
  script, commit everything it rewrote. Never hand-edit a derived PNG or SVG.
- **Palette and proportions live in two places** — the script and
  `Presentation/DesignSystem/Brand/ZynSignMark.swift` (`ZynBrand`). Change both or neither.
- **Light and dark, always.** Every banner, lockup and mark ships both variants;
  Markdown uses `<picture>` with `prefers-color-scheme` to pick one.
- **SVGs are real vectors** (the traced path plus a gradient tile), so they scale
  cleanly and stay small.

## In-app usage

`ZynSignMark(size:)` renders the tile in SwiftUI and places `PenMark` over it.
It is the only way the logo appears in the app — splash, Home header,
onboarding, Settings, About, and the lock overlay all use it. `ZynSignLockup`
adds the wordmark. Do not draw the mark any other way.

## Screenshots, mockups, videos

Not yet captured. When they are, they go in `Assets/Screenshots/`, `Assets/Mockups/`
and `Assets/Videos/` with one device frame, one background, and one language for
every capture.
