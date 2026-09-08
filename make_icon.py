"""Generate the DriveStitch application icon (app.ico).

Draws a dark rounded tile, a disk platter and a bold blue stitch crossing it,
then saves a multi-resolution Windows .ico next to this script. Sizes <= 32px
get a simplified high-contrast variant (no arcs, continuous stitch) so the
design stays readable on the taskbar and in file listings.

Usage:
    python make_icon.py [preview_png_output_path]
"""

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw

TILE_TOP = (35, 38, 44)
TILE_BOTTOM = (19, 21, 25)
EDGE = (58, 61, 68)
ACCENT = (74, 163, 255)
ACCENT_DARK = (38, 92, 158)
PLATTER = (42, 45, 51)
PLATTER_RING = (106, 112, 120)
PLATTER_INNER = (58, 61, 68)
HUB = (106, 112, 120)
SHEEN = (140, 146, 155)
ARC = (86, 91, 99)

ICO_SIZES = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)]
SIMPLE_SIZES = (32, 24, 16)


def _w(frac: float, size: int) -> int:
    return max(1, round(frac * size))


def _stitch_pts(size: int) -> list[tuple[float, float]]:
    ax, ay = 0.156 * size, 0.664 * size
    bx, by = 0.844 * size, 0.336 * size
    n = 6
    amp = 0.09375 * size
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    px, py = -dy / length, dx / length
    pts = []
    for i in range(n + 1):
        t = i / n
        off = 0.0 if i in (0, n) else (amp if i % 2 else -amp)
        pts.append((ax + dx * t + px * off, ay + dy * t + py * off))
    return pts


def _dash_segments(
    pts: list[tuple[float, float]], dash: float, gap: float
) -> list[tuple[float, float, float, float]]:
    out: list[tuple[float, float, float, float]] = []
    on = True
    remaining = dash
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        seg = math.hypot(x2 - x1, y2 - y1)
        ux, uy = (x2 - x1) / seg, (y2 - y1) / seg
        pos = 0.0
        while pos < seg - 1e-6:
            step = min(remaining, seg - pos)
            if on:
                out.append(
                    (x1 + ux * pos, y1 + uy * pos, x1 + ux * (pos + step), y1 + uy * (pos + step))
                )
            pos += step
            remaining -= step
            if remaining <= 1e-6:
                on = not on
                remaining = dash if on else gap
    return out


def _caps(d: ImageDraw.ImageDraw, seg: tuple[float, float, float, float], r: float, color: tuple) -> None:
    x1, y1, x2, y2 = seg
    for x, y in ((x1, y1), (x2, y2)):
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def _platter(d: ImageDraw.ImageDraw, size: int, simple: bool) -> None:
    cx = cy = size / 2
    r = 0.297 * size
    d.ellipse(
        [cx - r, cy - r, cx + r, cy + r],
        fill=PLATTER,
        outline=PLATTER_RING,
        width=_w(0.0195, size),
    )
    if not simple:
        d.ellipse(
            [cx - 0.273 * size, cy - 0.273 * size, cx + 0.273 * size, cy + 0.273 * size],
            outline=SHEEN,
            width=_w(0.0156, size),
        )
        for radius, arcs in ((0.227, ((200, 250), (320, 10), (80, 130))), (0.258, ((120, 170), (230, 285)))):
            box = [cx - radius * size, cy - radius * size, cx + radius * size, cy + radius * size]
            for a0, a1 in arcs:
                d.arc(box, start=a0, end=a1, fill=ARC, width=_w(0.0117, size))
        d.ellipse(
            [cx - 0.195 * size, cy - 0.195 * size, cx + 0.195 * size, cy + 0.195 * size],
            outline=PLATTER_INNER,
            width=_w(0.0117, size),
        )
    hub = 0.051 * size if not simple else 0.062 * size
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=HUB)
    if not simple:
        dot = 0.0195 * size
        d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=TILE_BOTTOM)


def _stitch(d: ImageDraw.ImageDraw, size: int, simple: bool) -> None:
    pts = _stitch_pts(size)
    if simple:
        d.line(pts, fill=ACCENT_DARK, width=_w(0.105, size), joint="curve")
        d.line(pts, fill=ACCENT, width=_w(0.07, size), joint="curve")
        return
    dash = 0.0586 * size
    gap = 0.0352 * size
    for width, color, cap in (
        (_w(0.0742, size), ACCENT_DARK, 0.0371 * size),
        (_w(0.0469, size), ACCENT, 0.0234 * size),
    ):
        for seg in _dash_segments(pts, dash, gap):
            d.line([(seg[0], seg[1]), (seg[2], seg[3])], fill=color, width=width)
            _caps(d, seg, cap, color)
    for i, (x, y) in enumerate(pts):
        if 0 < i < len(pts) - 1:
            r = 0.0117 * size
            d.ellipse([x - r, y - r, x + r, y + r], fill=TILE_BOTTOM)


def draw_icon(size: int, simple: bool = False) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGBA", (size, size))
    g = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(TILE_TOP, TILE_BOTTOM))
        g.line([(0, y), (size, y)], fill=c + (255,))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=_w(0.219, size), fill=255
    )
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=_w(0.219, size),
        outline=EDGE,
        width=_w(0.0078, size),
    )
    _platter(d, size, simple)
    _stitch(d, size, simple)
    return img


def _ico_frame(ico_path: str, size: int) -> Image.Image:
    im = Image.open(ico_path)
    im.size = (size, size)
    return im.convert("RGBA")


def preview(ico_path: str, master: Image.Image, path: str) -> None:
    canvas = Image.new("RGB", (760, 470), (128, 128, 128))
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, 0, 380, 470], fill=(24, 26, 30))
    d.rectangle([380, 0, 760, 470], fill=(238, 240, 242))
    for x0 in (62, 442):
        canvas.paste(master, (x0, 36), master)
        x = x0
        for s in (48, 32, 24, 16):
            small = _ico_frame(ico_path, s)
            canvas.paste(small, (x, 316 - s), small)
            x += s + 18
    zoom16 = _ico_frame(ico_path, 16).resize((128, 128), Image.NEAREST)
    canvas.paste(zoom16, (70, 334), zoom16)
    canvas.paste(zoom16, (450, 334), zoom16)
    canvas.save(path)


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ico_path = os.path.join(here, "app.ico")
    frames = [draw_icon(s, simple=s in SIMPLE_SIZES) for (s, _) in ICO_SIZES]
    frames[0].save(ico_path, format="ICO", sizes=ICO_SIZES, append_images=frames[1:])
    print(f"ICO written: {ico_path}")
    png_path = os.path.join(here, "icon.png")
    frames[0].save(png_path, format="PNG")
    print(f"PNG written: {png_path}")
    if len(sys.argv) > 1:
        preview(ico_path, frames[0], sys.argv[1])
        print(f"Preview written: {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
