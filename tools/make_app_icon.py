#!/usr/bin/env python3
"""Draws the classic (macOS 14 and 15) app icon from Domenico's "App Icon a" artwork.

Apple's classic grid: a 1024 px canvas with an 824 px rounded rectangle (radius 185)
centred in it and the drop shadow inside the 100 px margin. The artwork sits at 88% of
the plate. bin/build-desktop turns the result into AppIcon.icns with sips and iconutil.

Usage:
  tools/make_app_icon.py light assets/icon/AppIcon-1024.png   # Paper plate (default icon)
  tools/make_app_icon.py dark  assets/icon/AppIcon-dark-1024.png
Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "assets", "icon", "source")
S, R, RAD = 1024, 824, 185
M = (S - R) // 2
ART = 0.88
PLATES = {"light": (246, 243, 238, 255), "dark": (17, 17, 19, 255)}  # Paper, his dark ground
ARTWORK = {"light": "App Icon a@4x.png", "dark": "App Icon a dark@4x.png"}


def rounded_mask(scale=4, outline=0):
    m = Image.new("L", (S * scale, S * scale), 0)
    box = (M * scale, M * scale, (M + R) * scale - 1, (M + R) * scale - 1)
    d = ImageDraw.Draw(m)
    if outline:
        d.rounded_rectangle(box, RAD * scale, outline=255, width=outline)
    else:
        d.rounded_rectangle(box, RAD * scale, fill=255)
    return m.resize((S, S), Image.LANCZOS)


def build(mode):
    art = Image.open(os.path.join(SOURCE, ARTWORK[mode])).convert("RGBA")
    plate_mask = rounded_mask()
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(plate_mask.point(lambda v: int(v * 0.30)))
    shadow = shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -10)).filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow)
    plate = Image.new("RGBA", (S, S), PLATES[mode])
    a = round(R * ART)
    plate.alpha_composite(art.resize((a, a), Image.LANCZOS), ((S - a) // 2, (S - a) // 2))
    plate.putalpha(plate_mask)
    canvas.alpha_composite(plate)
    if mode == "dark":  # hairline so the dark plate does not melt into a dark Dock
        edge = Image.new("RGBA", (S, S), (255, 255, 255, 0))
        edge.putalpha(rounded_mask(outline=6).point(lambda v: int(v * 0.10)))
        canvas.alpha_composite(edge)
    return canvas


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in PLATES:
        sys.exit(__doc__)
    build(sys.argv[1]).save(sys.argv[2], optimize=True)
