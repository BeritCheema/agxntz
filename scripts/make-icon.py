#!/usr/bin/env python3
"""Render Support/AppIcon.icns from the 3-dots logo (Support/logo.svg, copied
from the agxntzLand site's favicon).

The logo is a dark rounded square with three dots. For a macOS app icon it's
placed on Apple's icon grid: a 1024px canvas with the rounded square at 824px
(transparent margin), so it sits at the same visual size as other app icons.
Drawn with Pillow (4x supersampled for smooth edges) from the SVG's numbers,
then packed with iconutil.
"""
import os, shutil, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Support", "AppIcon.icns")

# Values from logo.svg (viewBox 0 0 32 32).
VIEW, RX = 32, 7
BG = "#08080a"
DOTS = [(16, 10.5, "#3fcf6e"), (11, 20, "#e8973a"), (21, 20, "#4da3ff")]
R = 3.4

def render(size: int) -> Image.Image:
    ss = 4                                   # supersample factor
    S = size * ss
    tile = 824 / 1024 * S                    # rounded square on Apple's grid
    off = (S - tile) / 2
    k = tile / VIEW
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([off, off, off + tile, off + tile], radius=RX * k, fill=BG)
    for cx, cy, color in DOTS:
        x, y, r = off + cx * k, off + cy * k, R * k
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    return im.resize((size, size), Image.LANCZOS)

def main():
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        render(base).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
        render(base * 2).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
    render(1024).save(os.path.join(HERE, "..", "Support", "AppIcon-1024.png"))
    shutil.rmtree(tmp)
    print("wrote", os.path.normpath(OUT))

if __name__ == "__main__":
    main()
