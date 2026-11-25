#!/usr/bin/env python3
"""Draws the DMG installer background: plain wind-rippled sand in the app's palette.

Layout follows docs/RELEASE_PLAN.md 1.1: 660 x 400 pt window, app icon centred at
(180, 190), Applications at (480, 190), 128 pt icons, labels just below. Writes
background.png (1x) and background@2x.png; bin/make-dmg merges them into a TIFF.
Needs Pillow and numpy.  Usage: dmg_background.py OUTPUT_DIR
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 660, 400
APP, APPS, ICON_Y = (180, 190), (480, 190), 190
INK = (107, 86, 58)           # warm brown for the headline
LANES = ["#3E80F3", "#2AC561", "#F4A02A", "#ED494A", "#8B5AF3"]
FONT_DIRS = ["/usr/share/fonts/opentype/inter", "/System/Library/Fonts", "/Library/Fonts",
             os.path.expanduser("~/Library/Fonts")]


def font(size, names=("Inter-Medium.otf", "SFNS.ttf", "HelveticaNeue.ttc", "Helvetica.ttc")):
    for d in FONT_DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default(size)


def noise(h, w, scale, rng):
    """Smooth value noise in [-1, 1]."""
    g = rng.standard_normal((h // scale + 3, w // scale + 3)).astype(np.float32)
    im = Image.fromarray(g, mode="F").resize((w + 3 * scale, h + 3 * scale), Image.BICUBIC)
    a = np.asarray(im)[scale:scale + h, scale:scale + w]
    return a / (np.abs(a).max() + 1e-6)


def sand(s):
    w, h = W * s, H * s
    rng = np.random.default_rng(7)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32) / s
    # base: light dry sand, a touch warmer and darker towards the bottom right
    t = (0.55 * y / H + 0.45 * x / W)[..., None]
    top, bottom = np.array([241, 231, 214], np.float32), np.array([228, 211, 184], np.float32)
    rgb = top * (1 - t) + bottom * t
    # wind ripples: bent sine crests, shaded as if lit from the upper left
    warp = 26 * noise(h, w, 90 * s, rng) + 9 * noise(h, w, 30 * s, rng)
    phase = (y + 0.18 * x + warp * 1.0) / 12.5 * 2 * np.pi
    height = np.sin(phase) + 0.35 * np.sin(2 * phase + 1.3)
    shade = np.gradient(height, axis=0) * s * 7.0
    fade = 0.55 + 0.45 * noise(h, w, 120 * s, rng)  # ripples come and go
    # calmer sand around the icons, so Finder's icons stay the focus
    for cx, cy in (APP, APPS):
        d = np.hypot(x - cx, (y - cy) * 1.1)
        fade *= 0.35 + 0.65 * np.clip((d - 60) / 70, 0, 1)
    rgb += (shade * fade * 3.4)[..., None] * np.array([1.0, 0.95, 0.85], np.float32)
    # grain: fine speckle plus a few darker and lighter grains
    rgb += rng.normal(0, 3.2, (h, w, 1)).astype(np.float32) * np.array([1, .97, .9], np.float32)
    specks = rng.random((h, w))
    rgb[specks > 0.9985] -= np.array([38, 34, 28], np.float32)
    rgb[specks < 0.0012] += np.array([14, 14, 12], np.float32)
    # soft vignette
    v = np.clip(1 - 0.10 * (((x - W / 2) / (W / 2)) ** 2 + ((y - H / 2) / (H / 2)) ** 2), 0.85, 1)
    rgb *= v[..., None]
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def pressed_pill(img, box, s, tint=None, depth=1.0):
    """A pill shape pressed into the sand: darker floor, shadow on the top edge, light lip below."""
    x0, y0, x1, y1 = [v * s for v in box]
    r = (x1 - x0) / 2 if (x1 - x0) < (y1 - y0) else (y1 - y0) / 2
    w, h = img.size

    def shape(dx=0, dy=0, grow=0):
        m = Image.new("L", (w, h), 0)
        ImageDraw.Draw(m).rounded_rectangle((x0 + dx - grow, y0 + dy - grow, x1 + dx + grow, y1 + dy + grow),
                                            r + grow, fill=255)
        return m

    base = shape()
    floor = Image.new("RGBA", (w, h), tint + (int(70 * depth),) if tint else (120, 96, 64, int(46 * depth)))
    img.alpha_composite(Image.composite(floor, Image.new("RGBA", (w, h)), base))
    # inner shadow from the top edge
    inner = Image.fromarray(np.minimum(np.asarray(base), 255 - np.asarray(shape(0, 2.2 * s)))).filter(
        ImageFilter.GaussianBlur(1.6 * s))
    sh = Image.new("RGBA", (w, h), (70, 52, 30, 0))
    sh.putalpha(inner.point(lambda v: int(v * 0.55 * depth)))
    img.alpha_composite(sh)
    # light lip just below the bottom edge
    lip = Image.fromarray(np.minimum(np.asarray(shape(0, 1.6 * s)), 255 - np.asarray(base))).filter(
        ImageFilter.GaussianBlur(1.0 * s))
    li = Image.new("RGBA", (w, h), (255, 250, 238, 0))
    li.putalpha(lip.point(lambda v: int(v * 0.7 * depth)))
    img.alpha_composite(li)


def hex_rgb(hx):
    return tuple(int(hx[i:i + 2], 16) for i in (1, 3, 5))


def draw(s):
    img = sand(s)
    # No plates behind the labels: Finder (macOS 26+) draws its own dark pill behind
    # icon labels, so they stay readable on the light sand in both appearances.
    # a trail of lane pills pressed into the sand, from the app towards Applications
    xs = [262, 292, 322, 352, 382]
    for i, (px, col) in enumerate(zip(xs, LANES)):
        hgt = 26 + 6 * (i % 2)
        cy = ICON_Y + (-6 if i % 2 == 0 else 6)
        pressed_pill(img, (px - 7, cy - hgt / 2, px + 7, cy + hgt / 2), s, tint=hex_rgb(col), depth=0.9)
    # chevron at the end of the trail
    chev = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(chev)
    d.line([(400 * s, (ICON_Y - 10) * s), (410 * s, ICON_Y * s), (400 * s, (ICON_Y + 10) * s)],
           fill=(122, 98, 66, 200), width=int(3 * s), joint="curve")
    img.alpha_composite(chev)
    # headline
    t = ImageDraw.Draw(img)
    f = font(int(17 * s))
    msg = "Drag to Applications to install"
    tw = t.textlength(msg, font=f)
    t.text(((W * s - tw) / 2, 50 * s), msg, font=f, fill=INK + (255,))
    return img.convert("RGB")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    draw(1).save(os.path.join(out, "background.png"))
    draw(2).save(os.path.join(out, "background@2x.png"))
