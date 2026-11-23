"""N11-3 / B100: pull HeaderMark's circle mask in ~4 % so the light rim is cut away.

Writes RGBA PNGs with filter 0 and zlib *stored* blocks (level 0), so the Linux guard test
(Batch111Tests) can read the pixels without an inflate library. Run once:  python -I Tools/b100_headermark.py
"""
import math, struct, sys, zlib
from PIL import Image

PULL = 0.95   # outer radius as a share of the half-width (51 -> 48.5 at 3x)

def write_png(path, im):
    w, h = im.size
    px = im.tobytes()
    raw = b"".join(b"\x00" + px[y * w * 4:(y + 1) * w * 4] for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 0)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

def fix(path):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    c = w / 2
    r_out = PULL * c
    p = im.load()
    for y in range(h):
        for x in range(w):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c)
            cover = max(0.0, min(1.0, r_out - d + 0.5))   # 1 px anti-aliased edge
            r, g, b, a = p[x, y]
            p[x, y] = (r, g, b, round(a * cover))
    write_png(path, im)

for path in sys.argv[1:] or ["App/Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@2x.png",
                             "App/Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@3x.png"]:
    fix(path)
    print("fixed", path)
