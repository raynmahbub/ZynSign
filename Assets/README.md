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

The mark is the **Z with integrated fountain-pen nib + signature swash on the
indigo tile** — white **Z** (bold top bar + diagonal stem that becomes the pen
barrel/collar + short bottom bar) whose diagonal terminates in a detailed
fountain-pen nib at the lower-left (shoulder, breather hole, slit) and an
under-line cursive swash — on a `120×120 rx 30` tile at `4,4` within the
`128×128` viewBox (full-bleed `1024×1024` for the app icon). The tile gradient
is `#6D6AF0 → #4B48C4` (light) and `#7C79F5 → #5A57D6` (dark surfaces). The
system renders the same Z+pen artwork everywhere: the SVG masters in `Brand/`
(embedded high-res raster of the Z+pen for pixel-accurate fidelity), the Xcode
app icon, the favicon suite, the social preview, and the SwiftUI `ZynSignMark`
(`PenMark` image in the asset catalog — now the transparent white Z+pen) in
`Presentation/DesignSystem/Brand/ZynSignMark.swift`.

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

All rasters are rendered from the same Z+pen artwork (white Z+pen on
transparent, supersampled 4× and Lanczos-downsampled from the 1024 master
`/tmp/zpen_modern_1024.png`) composited onto the gradient tile, so the Z bars,
pen barrel/collar, nib shoulder, breather hole, slit and signature swash stay
identical from the 32 px favicon to the 1024 px App Store icon.

## Brand rules

| Element | Rule |
|---|---|
| Geometry | One mark: the **Z+pen hybrid** (bold top bar, diagonal pen nib + barrel, short bottom bar, cursive swash). Never redraw it ad hoc — use `PenMark` from the asset catalog or copy the SVG in `Brand/Logo/logo-mark.svg` |
| Palette | Indigo `#6D6AF0`→`#4B48C4`, dark indigo `#7C79F5`→`#5A57D6`, ink `#1D1D1F` / paper `#F5F5F7`, dark surface `#15151D` |
| Surfaces | Every banner and diagram ships a light **and** a dark variant — GitHub renders both via `<picture>` |
| Icons | SF Symbols in the app; the same pen (white nib, slit, collar, barrel, swash) in brand art |
| Type | System stack (`-apple-system, SF Pro, Segoe UI, Roboto, …`) in SVG; tight tracking on display sizes |
| Screenshots | One device frame, one background, one language — identical treatment for every capture |
| Type of asset | Vectors wherever possible; rasters only where a raster is required (social preview, favicon, app icon) |
| Rendering | Rasters are the white Z+pen on transparent (1024 master), supersampled 4× and Lanczos-downsampled, composited onto the gradient; the same artwork scales from 16 px to 1024 px |

The master geometry is the 1024 full-bleed raster `/tmp/zpen_modern_1024.png`
(white Z+pen on gradient `#6D6AF0→#4B48C4`, Apple HIG modern flat) and its
transparent mask `/tmp/zpen_only_1024.png`. SVGs in `Brand/` embed that raster
for pixel accuracy; if the mark ever changes, it changes from a new 1024 master
first, every derived PNG is re-rendered from it, and the SwiftUI `ZynSignMark`
is updated to the same numbers. No hand-edited PNG is the source of truth.

## In-app usage

The app never ships an SVG. It draws the same Z+pen with SwiftUI
(`ZynSignMark` in `Presentation/DesignSystem/Brand/ZynSignMark.swift`):
a `LinearGradient` tile clipped to `RoundedRectangle(cornerRadius: size*0.234)`,
with an `Image("PenMark")` (white Z+pen on transparent, 1×/2×/3× in the catalog)
centered and padded by `size*0.06`. The same `PenMark` supplies every derived PNG.
`ZynSignAppMark` is a typealias of `ZynSignMark` so every existing call site
(`About`, `Settings` summary, `Home` welcome header) shows the authentic Z+pen
without duplicating the artwork.

## Regeneration

```sh
python3 /tmp/generate_zpen_all.py   # supersampled PIL renderer from /tmp/zpen_only_1024.png → AppIcon, favicons, logo PNGs, social previews
# SVGs embed the PNG for pixel accuracy. Do not hand-edit a PNG to fix geometry — regenerate from the 1024 master and re-run.
```
