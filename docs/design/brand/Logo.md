# Logo

## The mark

The **Z·Pen**: a capital Z whose diagonal is a fountain pen, finishing in a
signature flourish. One shape, one colour, drawn in a single gesture — the
same gesture the app animates on launch and on a successful sign.

| | File |
|---|---|
| Master (raster, 1024², transparent) | `Assets/Brand/Source/zpen-mark-1024.png` |
| Traced vector (1024 user units, even-odd) | `Assets/Brand/Source/zpen-mark.svg` |
| Mark on indigo tile, light / dark | `Assets/Brand/Logo/logo-mark.svg`, `logo-mark-dark.svg` (+ 128/256/512 PNG) |
| Monochrome, ink / white | `Assets/Brand/Logo/logo-monochrome.svg`, `logo-monochrome-white.svg` |
| Outline, ink / white | `Assets/Brand/Logo/logo-outline.svg`, `logo-outline-white.svg` |
| Lockup (tile + wordmark) | `Assets/Brand/Logo/logo-lockup.svg`, `logo-lockup-dark.svg` |
| Wordmark only | `Assets/Brand/Logo/wordmark.svg`, `wordmark-dark.svg` |
| In-app | `ZynSignMark(size:)` — `Presentation/DesignSystem/Brand/ZynSignMark.swift` |

## Geometry

* Tile corner: 22.37 % of the side, continuous curve (the iOS icon corner).
* The mark fills **66 %** of the tile height, optically centred. Never scale
  the mark inside the tile; regenerate.
* Master bounding box in the 1024 canvas: (197, 192) – (827, 900).

## Clear space and minimum size

* Clear space around the tile: **¼ of the tile side** on every edge.
* Minimum tile: 24 px on screen, 8 mm in print. Below that, use the monochrome
  mark without a tile.
* Lockup minimum: 120 px wide.

## Which variant

| Ground | Use |
|---|---|
| White / light neutral | Indigo tile (`logo-mark.svg`) or ink monochrome |
| Dark neutral | Indigo-dark tile (`logo-mark-dark.svg`) or white monochrome |
| Photographs, busy surfaces | Tile only — the tile carries its own ground |
| Single-colour print, engraving, embossing | Monochrome or outline |

## Don'ts

1. Don't recolour the mark; the mark is white on indigo or one ink.
2. Don't add shadows, bevels or glows beyond the tile's own glass overlays.
3. Don't rotate, skew or mirror; the pen writes left to right.
4. Don't set "ZynSign" in another face next to the tile — use the lockup.
5. Don't place the mark inside another shape (circles, badges, ribbons).
