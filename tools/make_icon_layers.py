#!/usr/bin/env python3
"""Writes the Icon Composer layers (1024 canvas) for assets/icon/AppIcon.icon from the
geometry of Domenico's "App Icon a" (514 px artboard): lanes.svg holds the six solid
pills with his 50% overlay gradient baked in, now.svg the three frosted "now" pills, which
icon.json marks as glass. Usage: tools/make_icon_layers.py assets/icon/AppIcon.icon/Assets
"""
import os, sys
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
K = 1024 / 514 * 0.90          # his 514 artboard scaled to 1024, 90% to sit inside the glass edge
OFF = (1024 - 514 * K) / 2
def pill(x0, y0, x1, y1):
    x0, y0, x1, y1 = [OFF + v * K for v in (x0, y0, x1, y1)]
    r = (x1 - x0) / 2
    return x0, y0, x1 - x0, y1 - y0, r
def hexrgb(h): return [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
def tohex(c): return "#" + "".join(f"{round(max(0, min(1, v)) * 255):02X}" for v in c)
def overlay(c, b, a=0.5):  # his 50% white->black overlay gradient, baked
    o = [2 * v * b if v <= .5 else 1 - 2 * (1 - v) * (1 - b) for v in c]
    return [v * (1 - a) + w * a for v, w in zip(c, o)]
lanes = [  # x0, y0, x1, y1, colour
    (64, 64.05, 174, 189.48, "#3E80F3"), (64, 236.12, 174, 448.11, "#2AC561"),
    (202, 83.68, 312, 251.66, "#F4A02A"), (202, 284.66, 312, 430.48, "#20B7A5"),
    (340, 64, 450, 212.72, "#ED494A"), (340, 247.95, 450, 448.17, "#8B5AF3"),
]
now = [  # the frosted "now" pills
    (53.48, 167.10, 176.52, 333.67, "#F1D8AA"), (192.41, 154.68, 321.59, 370.47, "#C52AAE"),
    (334.48, 115.47, 457.52, 294.59, "#AAC4F1"),
]
def svg(items, grad):
    defs, body = [], []
    for i, (x0, y0, x1, y1, col) in enumerate(items):
        x, y, w, h, r = pill(x0, y0, x1, y1)
        if grad:
            c = hexrgb(col)
            defs.append(f'<linearGradient id="g{i}" x1="0" y1="{y:.2f}" x2="0" y2="{y+h:.2f}" gradientUnits="userSpaceOnUse">'
                        f'<stop stop-color="{tohex(overlay(c, 1))}"/><stop offset="1" stop-color="{tohex(overlay(c, 0))}"/></linearGradient>')
            fill = f'url(#g{i})'
        else:
            fill = col
        body.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{r:.2f}" fill="{fill}"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + (f'<defs>{"".join(defs)}</defs>' if defs else '') + "".join(body) + '</svg>\n')
open(os.path.join(out, "lanes.svg"), "w").write(svg(lanes, True))
open(os.path.join(out, "now.svg"), "w").write(svg(now, False))
