"""The only way a real log becomes a test fixture (P3_DILEMMAS D1 S123).

Run on the PC:
    python Tools/anonymise.py KIND:INPUT:NAME [KIND:INPUT:NAME ...]

Writes CorckieCore/Tests/Fixtures/NAME.csv for each input. All inputs of one run
share one random rotation and one reference point, so files of the same ride
(e.g. merged CSV + Sensor Logger) still line up with each other.

KIND
  p2lab      P2 Lab scooter log  (time,step,app_state,bytes)
  nrf        nRF Connect log     (Timestamp,Source,Level,Line); keeps only the
             FFF2 packet lines and Connected / Disconnected
  merged     1-per-second merged ride CSV (time,lat,lon,...)
  sl-loc     Sensor Logger Location.csv
  sl-baro    Sensor Logger Barometer.csv

What it does
  1. Scooter packets stay exactly as they are (no location in them).
  2. GPS is moved to a fake origin in the Atlantic and rotated by a random angle
     that is never written down, so no real street can be recovered.
  3. Dates move to 2000-01-01 (time of day kept, for rush-hour style tests).
  4. It REFUSES to write a file if any coordinate lands outside the fake box, or if
     any number in the output still looks like the real reference location.
"""
import csv
import io
import math
import random
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

FAKE_LAT, FAKE_LON = 10.0, -30.0          # open ocean, west of Africa
BOX = (9.5, 10.5, -30.5, -29.5)           # lat min, lat max, lon min, lon max
HEADER = "# corckie-fixture v1 · anonymised by Tools/anonymise.py · kind={kind} · dates→2000-01-01 · gps→fake origin {lat},{lon}, rotated"
OUT = Path(__file__).resolve().parent.parent / "CorckieCore/Tests/Fixtures"
EPOCH_2000 = datetime(2000, 1, 1, tzinfo=timezone.utc)


class Refused(Exception):
    pass


class Transform:
    def __init__(self):
        self.ref = None
        self.seen = set()   # real coordinates, cut to 5 decimals, for the leak check
        self.theta = math.radians(random.SystemRandom().uniform(30, 330))

    def point(self, lat, lon):
        for v in (lat, lon):
            self.seen.add(f"{v:.9f}".split(".")[0] + "." + f"{v:.9f}".split(".")[1][:5])
        if self.ref is None:
            self.ref = (lat, lon)
        lat0, lon0 = self.ref
        dx = (lon - lon0) * 111_320 * math.cos(math.radians(lat0))
        dy = (lat - lat0) * 110_540
        c, s = math.cos(self.theta), math.sin(self.theta)
        rx, ry = dx * c - dy * s, dx * s + dy * c
        new_lat = FAKE_LAT + ry / 110_540
        new_lon = FAKE_LON + rx / (111_320 * math.cos(math.radians(FAKE_LAT)))
        if not (BOX[0] <= new_lat <= BOX[1] and BOX[2] <= new_lon <= BOX[3]):
            raise Refused(f"coordinate outside the fake box after transform ({new_lat:.4f}, {new_lon:.4f})")
        return new_lat, new_lon

    def bearing(self, deg):
        # Bearings turn with the track (compass is clockwise, rotation is counter-clockwise)
        return (deg - math.degrees(self.theta)) % 360


def iso_to_2000(text):
    # 2026-10-02T08:17:30.072Z -> 2000-01-01T08:17:30.072Z
    return re.sub(r"^\d{4}-\d{2}-\d{2}", "2000-01-01", text)


def ns_to_2000(ns):
    t = int(ns)
    day = 86_400 * 10**9
    days_since = (t - int(EPOCH_2000.timestamp()) * 10**9) // day
    return str(t - days_since * day)


def fmt(v):
    return f"{v:.7f}"


def round_others(row, keep):
    """Other float columns to 4 decimals: no information lost, and no long number can
    collide with a real coordinate in the leak check."""
    for i, v in enumerate(row):
        if i not in keep and re.fullmatch(r"-?\d+\.\d{5,}", v):
            row[i] = f"{float(v):.4f}"
    return row


def do_p2lab(rows, tf):
    out = [rows[0]]
    for r in rows[1:]:
        if r:
            r[0] = iso_to_2000(r[0])
            out.append(r)
    return out


NRF_KEEP = re.compile(r"^(Updated Value of Characteristic FFF2 to |Connected\.$|Disconnected\.$)")


def do_nrf(rows, tf):
    out = [rows[0]]
    for r in rows[1:]:
        if len(r) >= 4 and r[2] == "Normal" and NRF_KEEP.match(r[3]):
            out.append(r[:4])
    return out


def do_merged(rows, tf):
    head = rows[0]
    head[0] = head[0].lstrip("\ufeff")
    ilat, ilon = head.index("lat"), head.index("lon")
    out = [head]
    for r in rows[1:]:
        if not r:
            continue
        if r[ilat] and r[ilon]:
            la, lo = tf.point(float(r[ilat]), float(r[ilon]))
            r[ilat], r[ilon] = fmt(la), fmt(lo)
        out.append(round_others(r, {ilat, ilon}))
    return out


def do_sl_loc(rows, tf):
    head = rows[0]
    it, ilat, ilon, ib = head.index("time"), head.index("latitude"), head.index("longitude"), head.index("bearing")
    out = [head]
    for r in rows[1:]:
        if not r:
            continue
        r[it] = ns_to_2000(r[it])
        la, lo = tf.point(float(r[ilat]), float(r[ilon]))
        r[ilat], r[ilon] = fmt(la), fmt(lo)
        if float(r[ib]) >= 0:
            r[ib] = f"{tf.bearing(float(r[ib])):.3f}"
        out.append(round_others(r, {it, ilat, ilon}))
    return out


def do_sl_baro(rows, tf):
    head = rows[0]
    it = head.index("time")
    out = [head]
    for r in rows[1:]:
        if r:
            r[it] = ns_to_2000(r[it])
            out.append(round_others(r, {it}))
    return out


KINDS = {"p2lab": do_p2lab, "nrf": do_nrf, "merged": do_merged, "sl-loc": do_sl_loc, "sl-baro": do_sl_baro}


def leak_check(text, tf, real_dates):
    """Every real coordinate seen (cut to 5 decimals, ~1 m) must be gone from the output."""
    found = {m[:m.index(".") + 6] for m in re.findall(r"(?<![\d.])-?\d+\.\d{5,}", text)}
    leaked = found & tf.seen
    if leaked:
        raise Refused(f"a real coordinate ({sorted(leaked)[0]}…) is still in the output")
    for d in real_dates:
        if d in text:
            raise Refused(f"the real date {d} is still in the output")


def main(args):
    if not args:
        print(__doc__)
        return 2
    tf = Transform()
    jobs = []
    for a in args:
        kind, rest = a.split(":", 1)          # INPUT may contain a drive letter (C:\...)
        src, name = rest.rsplit(":", 1)
        if kind not in KINDS:
            raise SystemExit(f"unknown kind {kind}")
        jobs.append((kind, Path(src), name))

    results = []
    for kind, src, name in jobs:
        raw = src.read_text(encoding="utf-8-sig", errors="replace")
        real_dates = set(re.findall(r"20\d\d-\d\d-\d\d", raw)) - {"2000-01-01"}
        rows = list(csv.reader(io.StringIO(raw)))
        out_rows = KINDS[kind](rows, tf)
        buf = io.StringIO()
        buf.write(HEADER.format(kind=kind, lat=FAKE_LAT, lon=FAKE_LON) + "\n")
        csv.writer(buf, lineterminator="\n").writerows(out_rows)
        results.append((name, buf.getvalue(), real_dates, len(out_rows) - 1))

    for name, text, real_dates, n in results:
        leak_check(text, tf, real_dates)
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text, _, n in results:
        target = OUT / f"{name}.csv"
        target.write_text(text, encoding="utf-8", newline="\n")
        print(f"{target.name}: {n} rows, {len(text) // 1024} KB")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as e:
        print(f"REFUSED: {e}. Nothing was written.", file=sys.stderr)
        sys.exit(1)
