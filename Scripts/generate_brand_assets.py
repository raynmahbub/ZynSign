#!/usr/bin/env python3
"""
generate_brand_assets.py — render every ZynSign brand asset from one master.

Master:  Assets/Brand/Source/zpen-mark-1024.png
         The Z·Pen mark as white-on-transparent, 1024×1024. It is the only
         hand-authored artwork in the brand system. Everything below is derived
         from it and must never be edited by hand.

Outputs:
  ZynSign/Resources/Assets.xcassets/AppIcon.appiconset/   iOS app icon (light · dark · tinted)
  ZynSign/Resources/Assets.xcassets/PenMark.imageset/     transparent mark @1x/@2x/@3x for ZynSignMark
  Assets/Brand/AppIcon/                                   app-icon master SVG + 1024 PNG references
  Assets/Brand/Logo/                                      logo mark (SVG + PNG, light/dark) and lockups
  Assets/Brand/Banner/                                    README banners (light/dark SVG)
  Assets/Brand/Favicon/                                   favicon SVG/PNG/ICO, touch + android icons
  Assets/Brand/Social/                                    GitHub social preview (1280×640, dark + light)

The SVGs carry the mark as a real vector path, traced from the master; the
rasters are rendered 4× supersampled and Lanczos-downsampled so the same
geometry survives from 16 px to 1024 px.

Usage:
    python3 Scripts/generate_brand_assets.py           # write everything
    python3 Scripts/generate_brand_assets.py --check   # exit 1 if any output would change

Requires: Pillow, numpy, opencv-python-headless (tracing only).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "Assets/Brand/Source/zpen-mark-1024.png"
BRAND = ROOT / "Assets/Brand"
XCASSETS = ROOT / "ZynSign/Resources/Assets.xcassets"

SS = 4  # supersampling factor for rasters

# ---------------------------------------------------------------------------
# Palette — the same numbers as Presentation/DesignSystem/Brand/ZynSignMark.swift
# ---------------------------------------------------------------------------
INDIGO_LIGHT = ((0x6D, 0x6A, 0xF0), (0x4B, 0x48, 0xC4))
INDIGO_DARK = ((0x7C, 0x79, 0xF5), (0x5A, 0x57, 0xD6))
ICON_DARK_BG = ((0x1E, 0x1C, 0x34), (0x0C, 0x0C, 0x14))
INK = "#1D1D1F"
PAPER = "#F5F5F7"
SURFACE_DARK = "#15151D"
MUTED_LIGHT = "#6E6E73"
MUTED_DARK = "#A1A1AA"

# Mark occupies this fraction of the tile height, centred (iOS icon safe zone).
MARK_FILL = 0.66
# iOS icon corner: 22.37 % of side, continuous curve. Used for every tile.
CORNER = 0.2237


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------
def squircle_mask(size: int, radius_ratio: float = CORNER, exponent: float = 4.6) -> Image.Image:
    """Continuous-corner (superellipse) mask, the shape iOS uses for icons."""
    r = size * radius_ratio
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    dx = np.clip(np.maximum(r - x, x - (size - r)), 0, None) / r
    dy = np.clip(np.maximum(r - y, y - (size - r)), 0, None) / r
    inside = (dx ** exponent + dy ** exponent) <= 1.0
    return Image.fromarray((inside * 255).astype(np.uint8), "L")


def diagonal_gradient(size: int, c0, c1) -> Image.Image:
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    t = ((x + y) / (2 * (size - 1)))[..., None]
    a = np.array(c0, np.float64)
    b = np.array(c1, np.float64)
    rgb = a + (b - a) * t
    return Image.fromarray(rgb.astype(np.uint8), "RGB")


def glass_overlays(size: int, strength: float = 1.0) -> Image.Image:
    """Restrained Liquid-Glass sheen: soft lens highlight + hairline top specular."""
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    # Lens highlight: a large soft ellipse across the upper third.
    lens = Image.new("L", (size, size), 0)
    ImageDraw.Draw(lens).ellipse(
        (-size * 0.35, -size * 0.75, size * 1.35, size * 0.55), fill=int(255 * 0.10 * strength)
    )
    lens = lens.filter(ImageFilter.GaussianBlur(size * 0.06))
    overlay.paste((255, 255, 255, 255), (0, 0), lens)
    # Top specular hairline.
    spec = Image.new("L", (size, size), 0)
    h = max(2, int(size * 0.045))
    for i in range(h):
        alpha = int(255 * 0.30 * strength * (1 - i / h) ** 2)
        ImageDraw.Draw(spec).line([(0, i), (size, i)], fill=alpha)
    overlay.paste((255, 255, 255, 255), (0, 0), spec)
    # Faint bottom glow for depth.
    glow = Image.new("L", (size, size), 0)
    g = max(2, int(size * 0.08))
    for i in range(g):
        alpha = int(255 * 0.05 * strength * (i / g) ** 2)
        ImageDraw.Draw(glow).line([(0, size - g + i), (size, size - g + i)], fill=alpha)
    overlay.paste((255, 255, 255, 255), (0, 0), glow)
    del draw
    return overlay


# ---------------------------------------------------------------------------
# Master mark
# ---------------------------------------------------------------------------
class Mark:
    def __init__(self, path: Path):
        img = Image.open(path).convert("RGBA")
        if img.size != (1024, 1024):
            raise SystemExit(f"{path} must be 1024×1024, got {img.size}")
        self.alpha = img.getchannel("A")
        self.bbox = self.alpha.getbbox()  # (l, t, r, b)

    def render(self, height: int, color=(255, 255, 255)) -> Image.Image:
        """The mark cropped to its bounds and scaled to `height` px tall (RGBA)."""
        l, t, r, b = self.bbox
        crop = self.alpha.crop(self.bbox)
        w = round(crop.width * height / crop.height)
        big = crop.resize((w * SS, height * SS), Image.LANCZOS)
        a = big.resize((w, height), Image.LANCZOS)
        out = Image.new("RGBA", (w, height), color + (0,))
        out.putalpha(a)
        return out

    def trace_svg_path(self) -> str:
        """A vector path (1024 user units, evenodd) traced from the master."""
        try:
            import cv2  # noqa: WPS433 — optional dependency, tracing only
        except ImportError:  # pragma: no cover
            raise SystemExit("opencv-python-headless is required to trace the SVG path")
        a = np.asarray(self.alpha)
        s = 4
        big = cv2.resize(a, (1024 * s, 1024 * s), interpolation=cv2.INTER_CUBIC)
        big = cv2.GaussianBlur(big, (0, 0), 1.5)
        contours, _ = cv2.findContours((big > 127).astype(np.uint8), cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        parts = []
        for c in contours:
            if cv2.contourArea(c) < 40 * s * s:
                continue
            approx = cv2.approxPolyDP(c, 0.9, True)
            pts = " L".join(f"{p[0][0] / s:.1f} {p[0][1] / s:.1f}" for p in approx)
            parts.append(f"M{pts}Z")
        return " ".join(parts)


def place_mark(tile: Image.Image, mark: Mark, fill: float = MARK_FILL, color=(255, 255, 255), dy: float = 0.0) -> Image.Image:
    size = tile.width
    glyph = mark.render(int(size * fill), color)
    x = (size - glyph.width) // 2
    y = (size - glyph.height) // 2 + int(size * dy)
    out = tile.convert("RGBA")
    out.alpha_composite(glyph, (x, y))
    return out


# ---------------------------------------------------------------------------
# Tiles
# ---------------------------------------------------------------------------
def tile(size: int, variant: str = "light", rounded: bool = True, glass: float = 1.0) -> Image.Image:
    """The indigo tile. `rounded=False` gives the full-bleed iOS app icon."""
    if variant == "light":
        base = diagonal_gradient(size, *INDIGO_LIGHT)
    elif variant == "dark":
        base = diagonal_gradient(size, *INDIGO_DARK)
    elif variant == "icon-dark":
        base = diagonal_gradient(size, *ICON_DARK_BG)
    else:
        raise ValueError(variant)
    img = base.convert("RGBA")
    img.alpha_composite(glass_overlays(size, glass))
    if rounded:
        img.putalpha(squircle_mask(size))
    return img


def downsample(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


def render_mark_tile(mark: Mark, size: int, variant="light", rounded=True, glass=1.0, border=False) -> Image.Image:
    big = size * SS
    img = place_mark(tile(big, variant, rounded, glass), mark)
    if border and rounded:
        # Hairline inner edge so the tile reads on white pages.
        edge = squircle_mask(big)
        inner = squircle_mask(big - 2 * SS).resize((big - 2 * SS, big - 2 * SS))
        ring = Image.new("L", (big, big), 0)
        ring.paste(edge, (0, 0))
        ring.paste(0, (SS, SS), inner)
        ring = ring.point(lambda v: int(v * 0.16))
        img.paste((255, 255, 255, 255), (0, 0), ring)
    return downsample(img, size)


# ---------------------------------------------------------------------------
# SVG builders — real vector path, vector gradient tile
# ---------------------------------------------------------------------------
FONT_DISPLAY = "-apple-system, 'SF Pro Display', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
FONT_TEXT = "-apple-system, 'SF Pro Text', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"


def hexc(c) -> str:
    return "#%02X%02X%02X" % tuple(c)


def svg_mark_group(path_d: str, size: float, variant: str, x: float = 0, y: float = 0, uid: str = "m", full_bleed=False) -> str:
    """A `<g>` drawing the tile + mark at `size` user units, origin (x, y)."""
    c0, c1 = INDIGO_LIGHT if variant == "light" else INDIGO_DARK if variant == "dark" else ICON_DARK_BG
    r = 0 if full_bleed else size * CORNER
    s = size / 1024
    l, t, rgt, b = MARK.bbox
    bw, bh = rgt - l, b - t
    gh = size * MARK_FILL
    gs = gh / bh
    gx = (size - bw * gs) / 2
    gy = (size - bh * gs) / 2
    del s
    return f"""<g transform="translate({x:g} {y:g})">
    <defs>
      <linearGradient id="{uid}-tile" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="{hexc(c0)}"/><stop offset="1" stop-color="{hexc(c1)}"/>
      </linearGradient>
      <linearGradient id="{uid}-spec" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
      </linearGradient>
      <radialGradient id="{uid}-lens" cx="0.5" cy="-0.1" r="0.9">
        <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
      </radialGradient>
      <clipPath id="{uid}-clip"><rect width="{size:g}" height="{size:g}" rx="{r:g}"/></clipPath>
    </defs>
    <rect width="{size:g}" height="{size:g}" rx="{r:g}" fill="url(#{uid}-tile)"/>
    <g clip-path="url(#{uid}-clip)">
      <rect width="{size:g}" height="{size:g}" fill="url(#{uid}-lens)"/>
      <rect width="{size:g}" height="{size * 0.05:g}" fill="url(#{uid}-spec)"/>
    </g>
    <path transform="translate({gx:.3f} {gy:.3f}) scale({gs:.6f}) translate({-l} {-t})" d="{path_d}" fill="#FFFFFF" fill-rule="evenodd"/>
  </g>"""


def svg_document(width, height, body, label) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" '
        f'role="img" aria-label="{label}">\n{body}\n</svg>\n'
    )


def svg_logo_mark(path_d: str, variant: str) -> str:
    return svg_document(128, 128, svg_mark_group(path_d, 128, variant, uid="zs"), "ZynSign")


def svg_lockup(path_d: str, variant: str) -> str:
    ink = PAPER if variant == "dark" else INK
    body = svg_mark_group(path_d, 112, variant, 8, 8, uid="zs")
    body += (
        f'\n  <text x="144" y="90" font-family="{FONT_DISPLAY}" font-size="72" font-weight="700" '
        f'letter-spacing="-2.5" fill="{ink}">ZynSign</text>'
    )
    return svg_document(440, 128, body, "ZynSign")


def svg_banner(path_d: str, variant: str) -> str:
    dark = variant == "dark"
    bg = SURFACE_DARK if dark else PAPER
    ink = PAPER if dark else INK
    muted = MUTED_DARK if dark else MUTED_LIGHT
    chip_fill = "#1F1F2A" if dark else "#FFFFFF"
    chip_stroke = "#34343F" if dark else "#D6D6DB"
    glow = hexc(INDIGO_DARK[0] if dark else INDIGO_LIGHT[0])
    body = f"""  <defs>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{glow}" stop-opacity="{0.20 if dark else 0.14}"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1500" height="500" rx="28" fill="{bg}"/>
  <ellipse cx="260" cy="80" rx="440" ry="240" fill="url(#glow)"/>
  <ellipse cx="1360" cy="450" rx="440" ry="240" fill="url(#glow)"/>
  {svg_mark_group(path_d, 236, variant, 118, 132, uid="zs")}
  <text x="410" y="250" font-family="{FONT_DISPLAY}" font-size="104" font-weight="700" letter-spacing="-3" fill="{ink}">ZynSign</text>
  <text x="414" y="310" font-family="{FONT_TEXT}" font-size="34" fill="{muted}">On-device iOS signing, made Apple-quality.</text>
  <g font-family="{FONT_TEXT}" font-size="24" fill="{ink}">"""
    chips = [("iOS 17+", 122), ("SwiftUI", 122), ("On-device", 136), ("No servers", 142)]
    x = 414
    for label, w in chips:
        body += (
            f'\n    <rect x="{x}" y="346" width="{w}" height="48" rx="24" fill="{chip_fill}" stroke="{chip_stroke}"/>'
            f'\n    <text x="{x + w / 2:g}" y="377" text-anchor="middle">{label}</text>'
        )
        x += w + 16
    body += "\n  </g>"
    return svg_document(1500, 500, body, "ZynSign — on-device iOS signing, made Apple-quality")


def svg_favicon(path_d: str) -> str:
    return svg_document(32, 32, svg_mark_group(path_d, 32, "light", uid="zs"), "ZynSign")


def svg_app_icon(path_d: str) -> str:
    return svg_document(1024, 1024, svg_mark_group(path_d, 1024, "light", uid="zs", full_bleed=True), "ZynSign app icon")


# ---------------------------------------------------------------------------
# Single-colour, outline and wordmark variants (print, engraving, favicons on
# coloured ground, partner pages). Same traced path, no tile.
# ---------------------------------------------------------------------------
def _mark_only_transform(size: float) -> str:
    l, t, rgt, b = MARK.bbox
    bw, bh = rgt - l, b - t
    gs = size * 0.84 / max(bw, bh)
    gx = (size - bw * gs) / 2
    gy = (size - bh * gs) / 2
    return f"translate({gx:.3f} {gy:.3f}) scale({gs:.6f}) translate({-l} {-t})"


def svg_monochrome(path_d: str, color: str, label: str) -> str:
    body = f'  <path transform="{_mark_only_transform(128)}" d="{path_d}" fill="{color}" fill-rule="evenodd"/>'
    return svg_document(128, 128, body, label)


def svg_outline(path_d: str, color: str) -> str:
    # Stroke in master units so the line weight is 1.5 % of the mark's height at any size.
    body = (
        f'  <path transform="{_mark_only_transform(128)}" d="{path_d}" fill="none" '
        f'stroke="{color}" stroke-width="11" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>'
    )
    return svg_document(128, 128, body, "ZynSign Z·Pen mark, outline")


def svg_wordmark(variant: str) -> str:
    ink = PAPER if variant == "dark" else INK
    body = (
        f'  <text x="0" y="66" font-family="{FONT_DISPLAY}" font-size="72" font-weight="700" '
        f'letter-spacing="-2.5" fill="{ink}">ZynSign</text>'
    )
    return svg_document(292, 88, body, "ZynSign")


# ---------------------------------------------------------------------------
# Alternate app icons — one master, five grounds. Rendered full-bleed like the
# primary icon so they drop straight into an alternate-icon asset set.
# ---------------------------------------------------------------------------
ALTERNATE_ICONS = {
    # name: (top colour, bottom colour, glass strength, mark colour)
    "Crystal":   (INDIGO_LIGHT[0], INDIGO_LIGHT[1], 1.6, (255, 255, 255)),
    "Midnight":  (ICON_DARK_BG[0], ICON_DARK_BG[1], 0.55, (255, 255, 255)),
    "Blueprint": ((0x1C, 0x3F, 0x94), (0x0D, 0x1E, 0x4F), 0.4, (255, 255, 255)),
    "Frost":     ((0xF2, 0xF4, 0xFC), (0xCF, 0xD6, 0xF3), 0.7, INDIGO_LIGHT[1]),
    "Aurora":    (INDIGO_LIGHT[0], (0x2A, 0xB8, 0xAE), 1.0, (255, 255, 255)),
}


def alternate_icon(mark: Mark, name: str) -> Image.Image:
    c0, c1, glass, mark_color = ALTERNATE_ICONS[name]
    big = 1024 * SS
    base = diagonal_gradient(big, c0, c1).convert("RGBA")
    base.alpha_composite(glass_overlays(big, glass))
    if name == "Blueprint":
        # A faint drafting grid, the one flourish the name earns.
        grid = Image.new("L", (big, big), 0)
        d = ImageDraw.Draw(grid)
        step = big // 16
        for i in range(1, 16):
            d.line((i * step, 0, i * step, big), fill=255, width=SS)
            d.line((0, i * step, big, i * step), fill=255, width=SS)
        base.paste((255, 255, 255, 255), (0, 0), grid.point(lambda v: int(v * 0.08)))
    if name == "Midnight":
        halo = Image.new("L", (big, big), 0)
        ImageDraw.Draw(halo).ellipse((big * 0.15, big * 0.15, big * 0.85, big * 0.85), fill=int(255 * 0.35))
        base.paste(hexc(INDIGO_DARK[0]), (0, 0), halo.filter(ImageFilter.GaussianBlur(big * 0.14)))
    return downsample(place_mark(base, mark, color=mark_color), 1024).convert("RGB")


# ---------------------------------------------------------------------------
# Living logo — the README hero. The ribbon draws itself along the Z
# diagonal, the wordmark settles in, one specular pass crosses the mark,
# then it rests. Roughly 3.6 s, loops.
# ---------------------------------------------------------------------------
HERO_W, HERO_H = 800, 300


def _hero_background() -> Image.Image:
    W, H = HERO_W, HERO_H
    img = Image.new("RGBA", (W, H), SURFACE_DARK)
    for cx, cy, a in ((140, 40, 0.22), (700, 290, 0.16)):
        halo = Image.new("L", (W, H), 0)
        ImageDraw.Draw(halo).ellipse((cx - 260, cy - 160, cx + 260, cy + 160), fill=int(255 * a))
        img.paste(hexc(INDIGO_DARK[0]), (0, 0), halo.filter(ImageFilter.GaussianBlur(70)))
    return img


def _diagonal_reveal(size: int, progress: float, softness: float = 0.18) -> Image.Image:
    """An L mask that opens from bottom-left to top-right — the pen's stroke direction."""
    ramp = np.linspace(0.0, 1.0, size, dtype=np.float32)
    # u = 0 at bottom-left, 1 at top-right.
    u = (ramp[None, :] + (1.0 - ramp)[:, None]) / 2.0
    edge = progress * (1.0 + softness) - softness
    m = np.clip((edge - u) / softness + 1.0, 0.0, 1.0)
    return Image.fromarray((m * 255).astype(np.uint8), "L")


def _shimmer(size: int, position: float) -> Image.Image:
    """A soft white diagonal band at `position` (0…1 across the tile)."""
    ramp = np.linspace(0.0, 1.0, size, dtype=np.float32)
    u = (ramp[None, :] + (1.0 - ramp)[:, None]) / 2.0
    band = np.exp(-((u - position) / 0.06) ** 2) * 0.45
    return Image.fromarray((band * 255).astype(np.uint8), "L")


def hero_frames(mark: Mark) -> tuple[list[Image.Image], list[int]]:
    bg = _hero_background()
    tile_size = 176
    tile_full = render_mark_tile(mark, tile_size, "dark")
    tile_x, tile_y = 84, (HERO_H - tile_size) // 2
    text_x = tile_x + tile_size + 48

    def ease(t: float) -> float:
        t = min(1.0, max(0.0, t))
        return 1 - (1 - t) ** 3  # ease-out cubic, the design language's curve

    frames, durations = [], []
    total = 40
    for i in range(total):
        t = i / (total - 1)
        img = bg.copy()
        # 1. Ribbon draws itself (0 – 45 % of the loop).
        reveal = ease(t / 0.45)
        tile_img = tile_full.copy()
        alpha = tile_img.getchannel("A")
        alpha = Image.fromarray((np.asarray(alpha, dtype=np.float32) * np.asarray(_diagonal_reveal(tile_size, reveal), dtype=np.float32) / 255).astype(np.uint8), "L")
        tile_img.putalpha(alpha)
        # 3. One specular pass (55 – 80 %).
        if 0.55 <= t <= 0.80:
            pos = (t - 0.55) / 0.25
            band = _shimmer(tile_size, pos)
            band = Image.fromarray((np.asarray(band, dtype=np.float32) * np.asarray(alpha, dtype=np.float32) / 255).astype(np.uint8), "L")
            tile_img.paste((255, 255, 255, 255), (0, 0), band)
        # Settle: a 4 px rise that eases out with the reveal.
        dy = int(round((1 - reveal) * 6))
        img.alpha_composite(tile_img, (tile_x, tile_y + dy))
        # 2. Wordmark and tagline settle in (30 – 65 %).
        fade = ease((t - 0.30) / 0.35)
        if fade > 0:
            layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            d.text((text_x, 96 + int((1 - fade) * 8)), "ZynSign", font=font("bold", 84), fill=PAPER)
            d.text((text_x + 4, 196 + int((1 - fade) * 8)), "On-device iOS signing, made Apple-quality.", font=font("regular", 22), fill=MUTED_DARK)
            la = layer.getchannel("A").point(lambda v: int(v * fade))
            layer.putalpha(la)
            img.alpha_composite(layer)
        frames.append(img.convert("RGB"))
        durations.append(60)
    durations[-1] = 1400  # rest before the loop
    return frames, durations


def gif_bytes(frames: list[Image.Image], durations: list[int]) -> bytes:
    palette_source = frames[-1].quantize(colors=160, method=Image.Quantize.MEDIANCUT)
    quantized = [f.quantize(palette=palette_source, dither=Image.Dither.FLOYDSTEINBERG) for f in frames]
    buf = io.BytesIO()
    quantized[0].save(buf, format="GIF", save_all=True, append_images=quantized[1:], duration=durations, loop=0, optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Raster deliverables
# ---------------------------------------------------------------------------
def app_icon_light(mark: Mark) -> Image.Image:
    img = place_mark(tile(1024 * SS, "light", rounded=False), mark)
    return downsample(img, 1024).convert("RGB")


def app_icon_dark(mark: Mark) -> Image.Image:
    # Dark appearance: deep indigo-black ground, soft indigo halo, white mark.
    big = 1024 * SS
    base = tile(big, "icon-dark", rounded=False, glass=0.55)
    halo = Image.new("L", (big, big), 0)
    ImageDraw.Draw(halo).ellipse((big * 0.15, big * 0.15, big * 0.85, big * 0.85), fill=int(255 * 0.35))
    halo = halo.filter(ImageFilter.GaussianBlur(big * 0.14))
    base.paste(hexc(INDIGO_DARK[0]), (0, 0), halo)
    return downsample(place_mark(base, mark), 1024).convert("RGB")


def app_icon_tinted(mark: Mark) -> Image.Image:
    # Tinted appearance: grayscale glyph on transparent — iOS supplies the fill.
    big = 1024 * SS
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    return downsample(place_mark(canvas, mark), 1024)


def pen_mark(mark: Mark, size: int) -> Image.Image:
    """Transparent white mark for `ZynSignMark`.

    The Swift view pads the image by 6 % per side, so a glyph 75 % of the
    canvas tall lands at MARK_FILL (66 %) of the tile — identical to the icon.
    """
    canvas = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    return downsample(place_mark(canvas, mark, fill=0.75), size)


def social_preview(mark: Mark, dark: bool) -> Image.Image:
    W, H = 1280, 640
    s = 2
    bg = SURFACE_DARK if dark else PAPER
    img = Image.new("RGBA", (W * s, H * s), bg)
    glow_c = INDIGO_DARK[0] if dark else INDIGO_LIGHT[0]
    for cx, cy in ((260, 80), (1100, 600)):
        halo = Image.new("L", (W * s, H * s), 0)
        ImageDraw.Draw(halo).ellipse(((cx - 420) * s, (cy - 260) * s, (cx + 420) * s, (cy + 260) * s), fill=int(255 * (0.22 if dark else 0.14)))
        halo = halo.filter(ImageFilter.GaussianBlur(120 * s))
        img.paste(hexc(glow_c), (0, 0), halo)
    tile_img = render_mark_tile(mark, 260 * s, "dark" if dark else "light")
    img.alpha_composite(tile_img, (120 * s, 190 * s))
    draw = ImageDraw.Draw(img)
    ink = PAPER if dark else INK
    muted = MUTED_DARK if dark else MUTED_LIGHT
    draw.text((430 * s, 232 * s), "ZynSign", font=font("bold", 108 * s), fill=ink)
    draw.text((436 * s, 372 * s), "On-device iOS signing, made Apple-quality.", font=font("regular", 34 * s), fill=muted)
    draw.text((436 * s, 424 * s), "iOS 17+  ·  SwiftUI  ·  No servers  ·  MIT", font=font("medium", 26 * s), fill=muted)
    return img.resize((W, H), Image.LANCZOS).convert("RGB")


_FONT_CACHE: dict = {}


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    key = (weight, size)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]
    candidates = {
        "bold": ["Roboto-Bold.ttf", "DejaVuSans-Bold.ttf"],
        "medium": ["Roboto-Medium.ttf", "DejaVuSans.ttf"],
        "regular": ["Roboto-Regular.ttf", "DejaVuSans.ttf"],
    }[weight]
    search = []
    try:
        import font_roboto  # type: ignore

        search.append(Path(font_roboto.__file__).parent / "files")
    except ImportError:
        pass
    search += [Path("/usr/share/fonts/truetype/dejavu"), Path("/System/Library/Fonts/Supplemental")]
    for name in candidates:
        for d in search:
            p = d / name
            if p.exists():
                f = ImageFont.truetype(str(p), size)
                _FONT_CACHE[key] = f
                return f
    f = ImageFont.load_default()
    _FONT_CACHE[key] = f
    return f


def ico_bytes(images: list[Image.Image]) -> bytes:
    """Multi-size ICO with PNG-compressed entries."""
    entries = []
    blobs = []
    offset = 6 + 16 * len(images)
    for im in images:
        buf = io.BytesIO()
        im.save(buf, "PNG")
        data = buf.getvalue()
        w, h = im.size
        entries.append(struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(data), offset))
        blobs.append(data)
        offset += len(data)
    return struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(blobs)


# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------
class Writer:
    def __init__(self, check: bool):
        self.check = check
        self.changed: list[Path] = []
        self.written = 0

    def put(self, path: Path, data: bytes):
        rel = path.relative_to(ROOT)
        current = path.read_bytes() if path.exists() else None
        if current == data:
            return
        # GIF quantisation is not byte-stable across Pillow releases; in
        # check mode an existing GIF only has to exist.
        if self.check and path.suffix == ".gif" and current is not None:
            return
        self.changed.append(rel)
        if not self.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.written += 1
            print(f"  wrote {rel}")

    def png(self, path: Path, img: Image.Image):
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        self.put(path, buf.getvalue())

    def text(self, path: Path, s: str):
        self.put(path, s.encode("utf-8"))


MARK: Mark


def main() -> int:
    global MARK
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="exit 1 if any generated asset would change")
    args = ap.parse_args()

    if not MASTER.exists():
        print(f"master not found: {MASTER}", file=sys.stderr)
        return 2
    MARK = Mark(MASTER)
    w = Writer(args.check)
    print(f"master {MASTER.relative_to(ROOT)} sha256 {hashlib.sha256(MASTER.read_bytes()).hexdigest()[:12]} bbox {MARK.bbox}")

    # --- iOS app icon ------------------------------------------------------
    icons = XCASSETS / "AppIcon.appiconset"
    light, dark, tinted = app_icon_light(MARK), app_icon_dark(MARK), app_icon_tinted(MARK)
    w.png(icons / "AppIcon-1024.png", light)
    w.png(icons / "AppIcon-dark-1024.png", dark)
    w.png(icons / "AppIcon-tinted-1024.png", tinted)
    w.text(icons / "Contents.json", json.dumps({
        "images": [
            {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-dark-1024.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-tinted-1024.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    # Reference copies for tooling and the brand tree.
    w.png(BRAND / "AppIcon/app-icon-1024.png", light)
    w.png(BRAND / "AppIcon/app-icon-dark-1024.png", dark)
    w.png(BRAND / "AppIcon/app-icon-tinted-1024.png", tinted)

    # --- PenMark (in-app transparent mark) ---------------------------------
    pen = XCASSETS / "PenMark.imageset"
    for scale, size in ((1, 128), (2, 256), (3, 384)):
        name = "PenMark.png" if scale == 1 else f"PenMark@{scale}x.png"
        w.png(pen / name, pen_mark(MARK, size))
    w.text(pen / "Contents.json", json.dumps({
        "images": [
            {"filename": "PenMark.png", "idiom": "universal", "scale": "1x"},
            {"filename": "PenMark@2x.png", "idiom": "universal", "scale": "2x"},
            {"filename": "PenMark@3x.png", "idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }, indent=2) + "\n")

    # --- Vector path + SVGs -------------------------------------------------
    path_d = MARK.trace_svg_path()
    w.text(BRAND / "Source/zpen-mark.svg", svg_document(
        1024, 1024, f'  <path d="{path_d}" fill="#FFFFFF" fill-rule="evenodd"/>', "ZynSign Z·Pen mark"))
    w.text(BRAND / "AppIcon/app-icon.svg", svg_app_icon(path_d))
    w.text(BRAND / "Logo/logo-mark.svg", svg_logo_mark(path_d, "light"))
    w.text(BRAND / "Logo/logo-mark-dark.svg", svg_logo_mark(path_d, "dark"))
    w.text(BRAND / "Logo/logo-lockup.svg", svg_lockup(path_d, "light"))
    w.text(BRAND / "Logo/logo-lockup-dark.svg", svg_lockup(path_d, "dark"))
    w.text(BRAND / "Banner/banner-light.svg", svg_banner(path_d, "light"))
    w.text(BRAND / "Banner/banner-dark.svg", svg_banner(path_d, "dark"))
    w.text(BRAND / "Favicon/favicon.svg", svg_favicon(path_d))

    # --- Logo PNGs ------------------------------------------------------------
    for size in (128, 256, 512):
        w.png(BRAND / f"Logo/logo-mark-{size}.png", render_mark_tile(MARK, size, "light"))
        w.png(BRAND / f"Logo/logo-mark-dark-{size}.png", render_mark_tile(MARK, size, "dark"))

    # --- Favicon suite ---------------------------------------------------------
    fav = BRAND / "Favicon"
    favs = {s: render_mark_tile(MARK, s, "light") for s in (16, 32, 48)}
    for s, im in favs.items():
        w.png(fav / f"favicon-{s}.png", im)
    w.put(fav / "favicon.ico", ico_bytes([favs[16], favs[32], favs[48]]))
    w.png(fav / "apple-touch-icon.png", downsample(place_mark(tile(180 * SS, "light", rounded=False), MARK), 180).convert("RGB"))
    for s in (192, 512):
        w.png(fav / f"android-chrome-{s}.png", downsample(place_mark(tile(s * SS, "light", rounded=False), MARK), s).convert("RGB"))
    w.text(fav / "site.webmanifest", json.dumps({
        "name": "ZynSign",
        "short_name": "ZynSign",
        "description": "On-device iOS signing, made Apple-quality.",
        "icons": [
            {"src": "android-chrome-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "android-chrome-512.png", "sizes": "512x512", "type": "image/png"},
            {"src": "apple-touch-icon.png", "sizes": "180x180", "type": "image/png"},
        ],
        "theme_color": hexc(INDIGO_LIGHT[0]),
        "background_color": SURFACE_DARK,
        "display": "standalone",
    }, indent=2) + "\n")

    # --- Social preview ----------------------------------------------------------
    w.png(BRAND / "Social/social-preview.png", social_preview(MARK, dark=True))
    w.png(BRAND / "Social/social-preview-light.png", social_preview(MARK, dark=False))
    w.png(BRAND / "Social/github-avatar.png", render_mark_tile(MARK, 512, "light", border=True))

    # --- Single-colour / outline / wordmark ---------------------------------------
    w.text(BRAND / "Logo/logo-monochrome.svg", svg_monochrome(path_d, INK, "ZynSign Z·Pen mark, monochrome"))
    w.text(BRAND / "Logo/logo-monochrome-white.svg", svg_monochrome(path_d, "#FFFFFF", "ZynSign Z·Pen mark, monochrome on dark"))
    w.text(BRAND / "Logo/logo-outline.svg", svg_outline(path_d, INK))
    w.text(BRAND / "Logo/logo-outline-white.svg", svg_outline(path_d, "#FFFFFF"))
    w.text(BRAND / "Logo/wordmark.svg", svg_wordmark("light"))
    w.text(BRAND / "Logo/wordmark-dark.svg", svg_wordmark("dark"))

    # --- Alternate app icons --------------------------------------------------------
    for name in ALTERNATE_ICONS:
        w.png(BRAND / f"AppIcon/Alternates/{name}.png", alternate_icon(MARK, name))

    # --- Living logo (README hero) ----------------------------------------------------
    frames, durations = hero_frames(MARK)
    w.put(BRAND / "Motion/hero.gif", gif_bytes(frames, durations))
    w.png(BRAND / "Motion/hero-still.png", frames[-1])

    if args.check:
        if w.changed:
            print("Brand assets are stale — run: python3 Scripts/generate_brand_assets.py")
            for p in w.changed:
                print(f"  {p}")
            return 1
        print("✓ Brand assets match the master.")
        return 0
    print(f"✓ Done — {w.written} file(s) written, {len(w.changed)} changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
