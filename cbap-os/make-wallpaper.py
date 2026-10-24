#!/usr/bin/env python3
"""Generate the CBAP OS wallpaper in the same visual language as the site."""
from __future__ import annotations
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

BG_TOP = (5, 8, 13)
BG_BOTTOM = (11, 29, 36)
TEAL = (94, 234, 212)
WHITE = (232, 238, 244)
MUTED = (147, 162, 177)
AMBER = (243, 201, 105)
PANEL = (10, 20, 28)
LINE = (31, 68, 72)


def font(paths, size):
    for p in paths:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def main(out: str, brand: str = "CBAP OS"):
    w, h = 1920, 1200
    im = Image.new("RGB", (w, h), BG_TOP)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=(
            int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t),
            int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t),
            int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t),
        ))

    # subtle engineering grid
    grid = (18, 42, 47)
    for x in range(0, w, 64):
        d.line([(x, 0), (x, h)], fill=grid, width=1)
    for y in range(0, h, 64):
        d.line([(0, y), (w, y)], fill=grid, width=1)

    # teal glow, composited so it stays soft
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((1180, 40, 1940, 800), fill=(20, 130, 125, 48))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    im = Image.alpha_composite(im.convert("RGBA"), glow).convert("RGB")
    d = ImageDraw.Draw(im)

    mono = ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
    bold = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    f_kicker = font(mono, 28)
    f_big = font(bold, 176)
    f_sub = font(mono, 34)
    f_small = font(mono, 24)
    f_term = font(mono, 26)

    d.text((140, 130), "CYBERDYNE / BRIDGE", font=f_kicker, fill=TEAL)
    d.text((140, 230), brand, font=f_big, fill=WHITE)
    d.text((146, 450), "VERSIONED RUNTIME  /  TRUST BOUNDARY", font=f_sub, fill=TEAL)
    d.line([(146, 530), (900, 530)], fill=TEAL, width=2)
    d.text((146, 570), "CBAP protocol · Python slots · explicit hot-swap",
           font=f_small, fill=MUTED)

    # terminal-style status panel
    x0, y0, x1, y1 = 1320, 210, 1780, 560
    d.rectangle((x0, y0, x1, y1), fill=PANEL, outline=LINE, width=2)
    d.text((x0 + 24, y0 + 22), "cbap-os status", font=f_term, fill=TEAL)
    rows = [
        ("CBAP", "v1.4.0"),
        ("PYTHON", "3.13"),
        ("SERVICE", "hand-gated"),
        ("AUDIT", "on"),
    ]
    for i, (k, v) in enumerate(rows):
        yy = y0 + 84 + i * 52
        d.text((x0 + 24, yy), k, font=f_term, fill=MUTED)
        d.text((x0 + 190, yy), v, font=f_term, fill=WHITE)
    d.text((x0 + 24, y1 - 42), "NO SHELL  /  ALLOWLIST ONLY", font=f_small, fill=AMBER)

    # bottom line
    d.line([(140, 1010), (1780, 1010)], fill=LINE, width=1)
    d.text((140, 1040), "CBAP OS 0.1  ·  Debian 13 trixie  ·  101/101 conformance",
           font=f_small, fill=MUTED)
    d.text((1400, 1040), "BOOT → SELECT → SWAP", font=f_small, fill=TEAL)

    out_p = Path(out)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    im.save(out_p)
    print(f"  ✔ {out_p} ({w}x{h})")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "CBAP OS")
