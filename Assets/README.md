# Assets

Visual assets for the repository and its public surfaces. The application's
runtime resources live in the Xcode project; everything here is for the README,
GitHub, and release communication.

Nothing in this tree is generated at build time, and nothing here is a
screenshot of a running build — screenshots live in `Screenshots/` once a
release capture pass has produced them, under the rules below.

## Layout

```
Assets/
├ Brand/            The identity system — one geometry, one palette
│ ├ Banner/         README hero banner (light + dark SVG)
│ ├ Logo/           Mark and lockup (light + dark SVG + PNG 128/256/512)
│ ├ AppIcon/        Master app-icon artwork (SVG, 1024×1024 canvas + PNG)
│ ├ Social/         GitHub social preview (1280×640 PNG, light + dark)
│ └ Favicon/        SVG + PNG suite + ICO + webmanifest
├ Screenshots/      Device-framed captures — one frame, one language (pending the 1.0.0 capture pass)
├ Mockups/          Presentation mockups (pending)
├ Videos/           Demo captures (pending)
└ Icons/            Supplementary icons (pending)
```

The shipping app icon is not in this tree: the Xcode project compiles
`ZynSign/Resources/Assets.xcassets` (AppIcon, 1024×1024, full-bleed and
opaque — the corner mask is the system's), rendered from the same master
geometry as `Brand/AppIcon/app-icon.svg`. A PNG copy is kept at
`Brand/AppIcon/app-icon-1024.png` for reference and for tooling that
needs a raster.

## Brand identity

The mark is the **bold Z over the seal dot on the indigo tile** — white
strokes `14 / 128` with `round` caps and joins, diagonal bezier
`M 38 42 H 90 C 76 56 60 70 40 86 H 90`, seal dot at `100,94 r 6.5`
on a `120×120 rx 30` tile at `4,4` within the `128×128` viewBox
(full-bleed `1024×1024` for the app icon). The tile gradient is
`#6D6AF0 → #4B48C4` (light) and `#7C79F5 → #5A57D6` (dark surfaces);
the seal is `#30D158`. The system renders the same geometry everywhere:
the SVG masters in `Brand/`, the Xcode app icon, and the SwiftUI
`ZynSignMark` in `Presentation/DesignSystem/Brand/ZynSignMark.swift`.

| Asset | File | Size / variant | Use |
|---|---|---|---|
| App icon master | `Brand/AppIcon/app-icon.svg` | 1024×1024 vector, full-bleed | Source for Xcode `AppIcon-1024.png` |
| App icon PNG | `ZynSign/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | 1024×1024, opaque | Shipping icon, light (Xcode compiles) |
| App icon dark | `ZynSign/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-dark-1024.png` | 1024×1024, `#7C79F5→#5A57D6` | Xcode dark appearance (iOS 18) |
| App icon tinted | `ZynSign/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-tinted-1024.png` | 1024×1024, flat | Xcode tinted appearance |
| App icon ref | `Brand/AppIcon/app-icon-1024.png` | 1024×1024 copy | Tooling / verification |
| App icon dark ref | `Brand/AppIcon/app-icon-dark-1024.png` | 1024×1024 | Tooling / verification |
| App icon tinted ref | `Brand/AppIcon/app-icon-tinted-1024.png` | 1024×1024 | Tooling / verification |
| Logo mark | `Brand/Logo/logo-mark.svg` | 128 vector, inset `120 rx 30` | Light surfaces |
| Logo mark dark | `Brand/Logo/logo-mark-dark.svg` | 128 vector, lighter indigo | Dark surfaces |
| Logo mark PNG | `Brand/Logo/logo-mark-{128,256,512}.png` | Raster, transparent | Docs, web, paste |
| Logo lockup | `Brand/Logo/logo-lockup.svg` | 560×128 mark + wordmark | Inline headers, docs |
| Logo lockup dark | `Brand/Logo/logo-lockup-dark.svg` | 560×128 lighter tile | Dark headers |
| Banner light | `Brand/Banner/banner-light.svg` | 1500×500 `#F5F5F7` | `README.md` light |
| Banner dark | `Brand/Banner/banner-dark.svg` | 1500×500 `#15151D` | `README.md` dark |
| Social preview | `Brand/Social/social-preview.png` | 1280×640 dark PNG | GitHub **Settings → Social preview** |
| Social light | `Brand/Social/social-preview-light.png` | 1280×640 light PNG | Alternate / future use |
| Favicon SVG | `Brand/Favicon/favicon.svg` | 32 vector `rx 8` | Modern browsers |
| Favicon PNG | `Brand/Favicon/favicon-{16,32,48}.png` | Raster, rounded `rx 0.25*size` | Tabs, bookmarks |
| Apple touch | `Brand/Favicon/apple-touch-icon.png` | 180×180 full-bleed | iOS home-screen bookmark |
| Android | `Brand/Favicon/android-chrome-{192,512}.png` | 192/512 full-bleed | PWA / install |
| ICO | `Brand/Favicon/favicon.ico` | 16/32/48 multi | Legacy browsers |
| Manifest | `Brand/Favicon/site.webmanifest` | JSON | `link rel="manifest"` |

All rasters are rendered from the SVG masters with the same stroking
(`stroke-linecap round`, `stroke-linejoin round`, single continuous path)
so there are no seam artifacts at the diagonal joints — the app icon's
diagonal is a single `C` bezier, not three overlapping strokes.

## Brand rules

| Element | Rule |
|---|---|
| Geometry | One mark: the bold Z over the seal dot. Never redraw it ad hoc — copy the `M 38 42 H 90 C 76 56 60 70 40 86 H 90` path and the `100,94 r 6.5` dot |
| Palette | Indigo `#6D6AF0`→`#4B48C4`, dark indigo `#7C79F5`→`#5A57D6`, ink `#1D1D1F` / paper `#F5F5F7`, dark surface `#15151D`, seal green `#30D158` |
| Surfaces | Every banner and diagram ships a light **and** a dark variant — GitHub renders both via `<picture>` |
| Icons | SF Symbols in the app; the same drawing logic (rounded strokes, one accent dot) in brand art |
| Type | System stack (`-apple-system, SF Pro, Segoe UI, Roboto, …`) in SVG; tight tracking on display sizes |
| Screenshots | One device frame, one background, one language — identical treatment for every capture |
| Type of asset | Vectors wherever possible; rasters only where a raster is required (social preview, favicon, app icon) |
| Rendering | Rasters are supersampled (4×) and Lanczos-downsampled; `stroke 14/128` scales linearly with the canvas; the dot scales as `6.5/128` |

The master geometry lives in the SVGs in `Brand/`. If the mark ever changes,
it changes there first, every derived PNG is re-rendered from it, and the
SwiftUI `ZynSignMark` is updated to the same numbers. No raster is ever the
source of truth.

## In-app usage

The app never ships an SVG. It draws the same geometry with SwiftUI
(`ZynSignMark` in `Presentation/DesignSystem/Brand/ZynSignMark.swift`):
a `LinearGradient` tile clipped to `RoundedRectangle(cornerRadius: size*0.234)`,
a `Canvas` stroked path `M 38 42 H 90 C 76 56 60 70 40 86 H 90` with
`lineCap .round` `lineJoin .round`, and an ellipse at `100,94 r 6.5`.
`ZynSignAppMark` is a typealias of `ZynSignMark` so every existing call site
(`About`, `Settings` summary, `Home` welcome header) shows the authentic mark
without duplicating the path.

## Regeneration

```sh
python3 /tmp/generate_all.py   # supersampled PIL renderer — writes AppIcon, favicons, logo PNGs, social previews
# SVGs are the source; PNGs are derived. Do not hand-edit a PNG to fix geometry — fix the SVG path and re-run.
```
