"""Draws the CorckieApp icon: a flat white kick-scooter on a blue gradient.

Usage (on the PC):  python Tools/make_icon.py [extra-copy.png ...]
Writes App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
(1024 x 1024, opaque RGB; iOS rounds the corners itself) and any extra copies.
Drawn at 4x and scaled down for smooth edges.
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

S = 4                      # supersampling factor
N = 1024 * S
TOP = (72, 210, 255)       # light sky blue
BOTTOM = (10, 92, 214)     # deep system blue
WHITE = (255, 255, 255)


def p(v):
    return int(round(v * S))


def gradient():
    n = 256  # small gradient, scaled up smoothly
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            t = min(1.0, max(0.0, (0.75 * y + 0.25 * x) / n))
            px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    return img.resize((N, N), Image.BILINEAR)


def line(d, a, b, w, fill=WHITE):
    d.line([(p(a[0]), p(a[1])), (p(b[0]), p(b[1]))], fill=fill, width=p(w))
    r = w / 2
    for (x, y) in (a, b):  # round caps
        d.ellipse([p(x - r), p(y - r), p(x + r), p(y + r)], fill=fill)


def ring(d, c, r, w, bg_sample):
    x, y = c
    d.ellipse([p(x - r), p(y - r), p(x + r), p(y + r)], fill=WHITE)
    ri = r - w
    d.ellipse([p(x - ri), p(y - ri), p(x + ri), p(y + ri)], fill=bg_sample(x, y))
    hub = 20
    d.ellipse([p(x - hub), p(y - hub), p(x + hub), p(y + hub)], fill=WHITE)


def main():
    img = gradient()
    d = ImageDraw.Draw(img)
    base = img.copy().load()

    def bg(x, y):
        return base[p(x), p(y)]

    rear, front, wr = (300, 712), (742, 712), 102
    # Deck, low between the wheels
    d.rounded_rectangle([p(268), p(650), p(668), p(698)], radius=p(24), fill=WHITE)
    # Rear fender over the back wheel
    fr, fw = wr + 34, 26
    d.arc([p(rear[0] - fr), p(rear[1] - fr), p(rear[0] + fr), p(rear[1] + fr)],
          start=200, end=285, fill=WHITE, width=p(fw))
    for ang in (200, 285):  # round fender ends
        a = math.radians(ang)
        cx, cy = rear[0] + (fr - fw / 2) * math.cos(a), rear[1] + (fr - fw / 2) * math.sin(a)
        d.ellipse([p(cx - fw / 2), p(cy - fw / 2), p(cx + fw / 2), p(cy + fw / 2)], fill=WHITE)
    # Neck from the deck up to the stem
    line(d, (640, 674), (717, 600), 46)
    # Stem leaning back toward the rider, from the front axle to the handlebar
    top = (640, 262)
    line(d, front, top, 50)
    # Handlebar (T-bar) with grips
    line(d, (556, 262), (724, 262), 50)
    # Wheels last so they sit on top
    ring(d, rear, wr, 36, bg)
    ring(d, front, wr, 36, bg)

    out = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    repo = Path(__file__).resolve().parent.parent
    target = repo / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    out.save(target, optimize=True)
    for extra in sys.argv[1:]:
        Path(extra).parent.mkdir(parents=True, exist_ok=True)
        out.save(extra, optimize=True)
    print(target, out.size, out.mode)


if __name__ == "__main__":
    main()
