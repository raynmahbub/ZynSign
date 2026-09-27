#!/usr/bin/env python3
"""Compose App Store / README screenshots from raw simulator captures.

Template (one rule, every screenshot):
  • indigo diagonal gradient ground, the brand's own two stops
  • a black iPhone frame with a continuous-corner bezel
  • a large headline (≤ 3 words) and one short subtitle above the device

Usage
  python3 Scripts/compose_screenshots.py                # Assets/Screenshots/manifest.json → Assets/Screenshots/store/
  python3 Scripts/compose_screenshots.py --preview      # renders the template with a placeholder capture
  python3 Scripts/compose_screenshots.py --manifest path/to/manifest.json --out dir

manifest.json
  [
    {"file": "raw/01-workspace.png", "headline": "One Workspace.", "subtitle": "Continue where you left off, sign in one tap."},
    ...
  ]

Raw captures are 1290×2796 (6.7-inch) or 1179×2556 (6.1-inch) PNGs straight
from the simulator; the script resizes to the canvas it is given. Nothing is
uploaded and nothing is fetched: this is Pillow and the brand palette.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:  # pragma: no cover
    sys.exit("pillow is required: pip install pillow")

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "Assets/Screenshots/manifest.json"
DEFAULT_OUT = ROOT / "Assets/Screenshots/store"

INDIGO = ((0x6D, 0x6A, 0xF0), (0x4B, 0x48, 0xC4))
PAPER = (0xF5, 0xF5, 0xF7)
CANVASES = {"6.7": (1290, 2796), "6.1": (1179, 2556), "ipad-13": (2064, 2752)}


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    names = {"bold": ["Roboto-Bold.ttf", "DejaVuSans-Bold.ttf"], "regular": ["Roboto-Regular.ttf", "DejaVuSans.ttf"]}[weight]
    search = []
    try:
        import font_roboto  # type: ignore

        search.append(Path(font_roboto.__file__).parent / "files")
    except ImportError:
        pass
    search += [Path("/usr/share/fonts/truetype/dejavu"), Path("/System/Library/Fonts/Supplemental")]
    for n in names:
        for d in search:
            if (d / n).exists():
                return ImageFont.truetype(str(d / n), size)
    return ImageFont.load_default()


def gradient(w: int, h: int) -> Image.Image:
    import numpy as np

    y, x = np.mgrid[0:h, 0:w].astype("float32")
    t = ((x / max(w - 1, 1)) + (y / max(h - 1, 1))) / 2
    c0, c1 = (np.array(c, dtype="float32") for c in INDIGO)
    rgb = c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
    return Image.fromarray(rgb.astype("uint8"), "RGB")


def device_frame(capture: Image.Image, width: int) -> Image.Image:
    """The capture inside a black continuous-corner frame, `width` px wide overall."""
    bezel = int(width * 0.028)
    radius = int(width * 0.16)
    inner_w = width - 2 * bezel
    inner_h = int(inner_w * capture.height / capture.width)
    shot = capture.resize((inner_w, inner_h), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner_w - 1, inner_h - 1), radius=radius - bezel, fill=255)
    shot.putalpha(mask)

    frame = Image.new("RGBA", (width, inner_h + 2 * bezel), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle((0, 0, width - 1, frame.height - 1), radius=radius, fill=(12, 12, 16, 255))
    d.rounded_rectangle((2, 2, width - 3, frame.height - 3), radius=radius - 2, outline=(60, 60, 70, 255), width=2)
    frame.alpha_composite(shot, (bezel, bezel))
    # Dynamic Island.
    iw, ih = int(inner_w * 0.28), int(inner_w * 0.082)
    d.rounded_rectangle(((width - iw) // 2, bezel + int(ih * 0.45), (width + iw) // 2, bezel + int(ih * 1.45)), radius=ih // 2, fill=(0, 0, 0, 255))
    return frame


def compose(capture: Image.Image, headline: str, subtitle: str, size: tuple[int, int]) -> Image.Image:
    W, H = size
    img = gradient(W, H).convert("RGBA")
    d = ImageDraw.Draw(img)
    hf, sf = font("bold", int(W * 0.088)), font("regular", int(W * 0.036))
    y = int(H * 0.075)
    for line in headline.split("\n"):
        d.text((W / 2, y), line, font=hf, fill=PAPER, anchor="ma")
        y += int(W * 0.10)
    d.text((W / 2, y + int(W * 0.015)), subtitle, font=sf, fill=(0xE4, 0xE4, 0xF7), anchor="ma")

    frame = device_frame(capture, int(W * 0.78))
    shadow = Image.new("RGBA", (frame.width + 160, frame.height + 160), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((80, 110, 80 + frame.width, 110 + frame.height), radius=int(frame.width * 0.16), fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    fx, fy = (W - frame.width) // 2, int(H * 0.27)
    img.alpha_composite(shadow, (fx - 80, fy - 80))
    img.alpha_composite(frame.crop((0, 0, frame.width, min(frame.height, H - fy))), (fx, fy))
    return img.convert("RGB")


def placeholder_capture() -> Image.Image:
    """A neutral stand-in so the template can be reviewed before real captures exist."""
    im = Image.new("RGB", (1290, 2796), (0xF2, 0xF2, 0xF7))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 1290, 160), fill=(0xF2, 0xF2, 0xF7))
    d.text((60, 190), "Good Morning", font=font("bold", 96), fill=(0x1D, 0x1D, 0x1F))
    y = 360
    for h in (360, 300, 260, 260, 260):
        d.rounded_rectangle((48, y, 1242, y + h), radius=44, fill=(255, 255, 255))
        d.rounded_rectangle((96, y + 48, 96 + 420, y + 48 + 34), radius=17, fill=(0xD9, 0xD9, 0xE3))
        d.rounded_rectangle((96, y + 110, 96 + 760, y + 110 + 26), radius=13, fill=(0xE7, 0xE7, 0xEE))
        y += h + 36
    return im


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--canvas", choices=sorted(CANVASES), default="6.7")
    ap.add_argument("--preview", action="store_true", help="render the template once with a placeholder capture")
    args = ap.parse_args()
    size = CANVASES[args.canvas]

    if args.preview:
        out = ROOT / "Assets/Screenshots/template-preview.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        compose(placeholder_capture(), "One Workspace.", "Continue where you left off. Sign in one tap.", size).resize((size[0] // 2, size[1] // 2), Image.LANCZOS).save(out, optimize=True)
        print(f"wrote {out.relative_to(ROOT)}")
        return 0

    if not args.manifest.exists():
        print(f"no manifest at {args.manifest} — see the docstring for the format", file=sys.stderr)
        return 2
    entries = json.loads(args.manifest.read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    for i, e in enumerate(entries, 1):
        src = (args.manifest.parent / e["file"]).resolve()
        if not src.exists():
            print(f"  missing capture: {src}", file=sys.stderr)
            return 1
        img = compose(Image.open(src).convert("RGB"), e["headline"], e.get("subtitle", ""), size)
        dest = args.out / f"{i:02d}-{args.canvas}-{Path(e['file']).stem}.png"
        img.save(dest, optimize=True)
        print(f"  wrote {dest.relative_to(ROOT)}")
    print(f"✓ {len(entries)} screenshot(s) at {size[0]}×{size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
