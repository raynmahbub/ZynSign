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
│ ├ Logo/           Mark and lockup (light + dark SVG)
│ ├ AppIcon/        Master app-icon artwork (SVG, 1024×1024 canvas)
│ ├ Social/         GitHub social preview (1280×640 PNG)
│ └ Favicon/        SVG + 32 px PNG
├ Screenshots/      Device-framed captures — one frame, one language (pending the 1.0.0 capture pass)
├ Mockups/          Presentation mockups (pending)
├ Videos/           Demo captures (pending)
└ Icons/            Supplementary icons (pending)
```

## Brand rules

| Element | Rule |
|---|---|
| Geometry | One mark: the Z-stroke tile with the seal dot. Never redraw it ad hoc |
| Palette | Indigo `#6D6AF0`→`#4B48C4`, ink `#1D1D1F` / paper `#F5F5F7`, dark surface `#15151D`, seal green `#30D158` |
| Surfaces | Every banner and diagram ships a light **and** a dark variant — GitHub renders both via `<picture>` |
| Icons | SF Symbols in the app; the same drawing logic (rounded strokes, one accent dot) in brand art |
| Type | System stack (`-apple-system, SF Pro, Segoe UI, Roboto, …`) in SVG; tight tracking on display sizes |
| Screenshots | One device frame, one background, one language — identical treatment for every capture |
| Type of asset | Vectors wherever possible; rasters only where a raster is required (social preview, favicon) |

The master geometry lives in the SVGs in `Brand/`. If the mark ever changes,
it changes there first, and every derived asset is re-rendered from it.
