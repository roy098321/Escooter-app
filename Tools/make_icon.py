"""Draws the CorckieApp icon: option C1 "stem decal" (owner pick, 11 Oct 2026).

Rider X Race Mini colours: beige main, dark grey band (the stem), orange
stencil C with paint splatter (the "RIDER X" decal).

Usage (on the PC):  python Tools/make_icon.py [extra-copy.png ...]
Writes App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
(1024 x 1024, opaque RGB; iOS rounds the corners itself) and any extra copies.
Drawn at 4x and scaled down for smooth edges.
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

BEIGE = (207, 184, 148)
BEIGE_LT = (224, 205, 172)
GREY = (79, 82, 81)
GREY_DK = (46, 49, 49)
ORANGE = (242, 138, 85)
ORANGE_DK = (214, 112, 64)

S = 4
N = 1024 * S


def p(v):
    return int(round(v * S))


def grad(c1, c2):
    g = Image.new("RGB", (256, 256))
    px = g.load()
    for y in range(256):
        for x in range(256):
            t = (0.7 * y + 0.3 * x) / 256
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    img = g.resize((N, N), Image.BILINEAR)
    return img, ImageDraw.Draw(img)


def band(d, col, half=310, angle=-45):
    """Diagonal band through the centre, `half` = half-width in px."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)          # along the band
    nx, ny = -uy, ux                           # across
    L = 1000
    pts = [(512 + ux * L + nx * half, 512 + uy * L + ny * half),
           (512 - ux * L + nx * half, 512 - uy * L + ny * half),
           (512 - ux * L - nx * half, 512 - uy * L - ny * half),
           (512 + ux * L - nx * half, 512 + uy * L - ny * half)]
    d.polygon([(p(x), p(y)) for x, y in pts], fill=col)
    return (ux, uy), (nx, ny)


def stencil_c(d, col, c=(512, 512), r=205, w=92, gaps=((40, 120), (128, 232), (240, 320))):
    box = [p(c[0] - r), p(c[1] - r), p(c[0] + r), p(c[1] + r)]
    for a0, a1 in gaps:
        d.arc(box, a0, a1, fill=col, width=p(w))


def dot(d, x, y, r, col):
    d.ellipse([p(x - r), p(y - r), p(x + r), p(y + r)], fill=col)


def splat(d, col, rnd, centre, n, rmin, rmax, inside):
    """Paint splatter: blobs with small satellites, only where inside(x, y)."""
    for _ in range(n):
        ang = rnd.uniform(0, 2 * math.pi)
        dist = rnd.uniform(rmin, rmax)
        x, y = centre[0] + math.cos(ang) * dist, centre[1] + math.sin(ang) * dist
        if not inside(x, y):
            continue
        r = rnd.uniform(4, 14)
        dot(d, x, y, r, col)
        for _ in range(rnd.randint(0, 3)):
            dot(d, x + rnd.uniform(-3, 3) * r, y + rnd.uniform(-3, 3) * r, r * rnd.uniform(0.25, 0.5), col)


def on_band(half):
    return lambda x, y: abs((x - 512) + (y - 512)) / math.sqrt(2) < half - 18


def c1():
    """C1 Refined: narrower band, cleaner C, fewer organic splatters + 2 drips."""
    img, d = grad(BEIGE_LT, BEIGE)
    band(d, GREY_DK, half=280)
    stencil_c(d, ORANGE, r=200, w=96, gaps=((35, 125), (133, 227), (235, 325)))
    rnd = random.Random(11)
    splat(d, ORANGE, rnd, (512, 512), 34, 255, 400, on_band(280))
    for x, y, L in ((612, 700, 70), (430, 330, 45)):        # drips
        d.rounded_rectangle([p(x - 7), p(y), p(x + 7), p(y + L)], radius=p(7), fill=ORANGE)
        dot(d, x, y + L, 11, ORANGE)
    return img



def main():
    root = Path(__file__).resolve().parent.parent
    out = root / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    img = c1().resize((1024, 1024), Image.LANCZOS)
    img.save(out)
    for extra in sys.argv[1:]:
        img.save(extra)
    print("wrote", out)


if __name__ == "__main__":
    main()
