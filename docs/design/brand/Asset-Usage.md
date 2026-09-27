# Asset usage

Every file below is generated; edit the master or the script, never the output.

| Where | File | Notes |
|---|---|---|
| README hero | `Assets/Brand/Motion/hero.gif` (800×300, ~0.5 MB) | Still fallback: `hero-still.png` |
| README / docs header | `Assets/Brand/Banner/banner-light.svg`, `banner-dark.svg` | Use the `<picture>` pattern for dark mode |
| Docs page header | `Assets/Brand/Logo/logo-lockup.svg` / `-dark.svg` at 260 px | |
| GitHub organisation / repo avatar | `Assets/Brand/Social/github-avatar.png` (512², hairline edge) | |
| GitHub social preview | `Assets/Brand/Social/social-preview.png` (1280×640) | Light variant available |
| Favicon / PWA | `Assets/Brand/Favicon/*` incl. `site.webmanifest` | |
| iOS app icon | `ZynSign/Resources/Assets.xcassets/AppIcon.appiconset` | Light, dark and tinted appearances, 1024² |
| Alternate icons (roadmap) | `Assets/Brand/AppIcon/Alternates/{Crystal,Midnight,Blueprint,Frost,Aurora}.png` | Full-bleed 1024²; wiring via `CFBundleIcons` is a v3.0 item |
| In-app mark | `PenMark.imageset` through `ZynSignMark(size:)` | Never `Image("PenMark")` directly |
| Print, engraving | `Assets/Brand/Logo/logo-monochrome*.svg`, `logo-outline*.svg` | Single colour |
| App Store screenshots | `python3 Scripts/compose_screenshots.py` | Template: `Assets/Screenshots/template-preview.png` |

## Regenerating

```bash
pip install pillow numpy opencv-python-headless font-roboto
python3 Scripts/generate_brand_assets.py          # write
python3 Scripts/generate_brand_assets.py --check  # CI
```

## Third parties

You may use the mark and lockup unchanged to refer to ZynSign (articles,
package listings, talks). You may not use them to imply endorsement, as part
of another logo, or on a product that installs applications — ZynSign does
not install, and its mark must not suggest that it does.
