"""Builds the frozen test database of a milestone (DATA_MODEL V7, TESTING §1 layer 4).

    python Tools/make_frozen_db.py          # 0.4 foundation (made once, never regenerated)
    python Tools/make_frozen_db.py --v10    # 1.0 freeze (schema v1 + v2 + v3, every table filled; made once)

Reads the schema SQL straight out of App/Store/Migrations/Migration0001.swift (between the
SQL-BEGIN / SQL-END markers), so it is the same SQL the app runs, marks migration "v1" as
applied the way GRDB does, and fills every table with synthetic rows (fake coordinates in
the anonymiser's ocean box, dates in 2000). Output: AppTests/Fixtures/p4-foundation.sqlite.

A frozen database is made ONCE per milestone and never regenerated: the migration test
proves every later build opens it with no row lost.
"""
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "App/Store/Migrations/Migration0001.swift"
OUT = ROOT / "AppTests/Fixtures/p4-foundation.sqlite"
OUT_V10 = ROOT / "AppTests/Fixtures/p5-1.0-frozen.sqlite"
T0 = 946_684_800_000  # 2000-01-01T00:00:00Z in ms


def schema_sql():
    text = SWIFT.read_text(encoding="utf-8")
    m = re.search(r"-- SQL-BEGIN v1\n(.*?)-- SQL-END v1", text, re.S)
    if not m:
        raise SystemExit("SQL markers not found")
    return m.group(1)


def migration_sql(n):
    """The SQL of Migration000<n>.swift (the `sql` string of the enum), as the app runs it."""
    text = (ROOT / f"App/Store/Migrations/Migration000{n}.swift").read_text(encoding="utf-8")
    m = re.search(r'static let sql = """' + chr(10) + r'(.*?)' + chr(10) + r'    """', text, re.S)
    if not m:
        raise SystemExit(f"sql of Migration000{n} not found")
    return m.group(1)


def main(v10=False):
    label = "1.0-frozen" if v10 else "0.4-frozen"
    out = OUT_V10 if v10 else OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    db = sqlite3.connect(out)
    db.executescript(schema_sql())
    db.execute("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    db.execute("INSERT INTO grdb_migrations VALUES ('v1')")
    if v10:
        for n in (2, 3):
            db.executescript(migration_sql(n))
            db.execute("INSERT INTO grdb_migrations VALUES (?)", (f"v{n}",))

    ins = db.execute
    ins("INSERT INTO scooter VALUES ('s1','G2','00000000-0000-0000-0000-000000000001',?,586.6,'BK-BLE-1.0','6.1.2','6.3.0','15,20,25',NULL)", (T0,))
    for k in range(3):
        rid = f"r{k}"
        start = T0 + k * 3_600_000
        ins("""INSERT INTO ride (id, scooterId, kind, status, startAt, endAt, utcOffsetMin, endReason,
               distanceM, totalS, movingS, energyWhRaw, usedPct, odoStartKm, odoEndKm, tempStartC, tempPeakC,
               ignoredReadings, hasGps, calcVersion, decoderVersion, createdBuild)
               VALUES (?,?,?,?,?,?,180,'scooterOff',?,?,?,?,?,?,?,26,92,0,1,1,1,?)""",
            (rid, "s1", "ride" if k < 2 else "shortHop", "ended", start, start + 1_800_000,
             13_700 - k * 100, 1800, 1700, 322.0 - k, 41.0, 602.9, 616.6, label))
        for t in range(0, 60_000, 1000):
            ins("""INSERT INTO ride_sample (rideId, t, speedMps, lat, lon, hAccM, voltage, currentA, batteryPct,
                   tempC, gear, capKmh, brake, light, odometerKm, mode, moving, distanceM)
                   VALUES (?,?,?,?,?,5,50.1,10.5,64,40,3,25,0,1,602.9,'scooter',1,?)""",
                (rid, t, 11.1, 10.0 + t / 1e8, -30.0 + t / 1e8, t * 11.1 / 1000))
        ins("INSERT INTO raw_chunk VALUES (?,?,0,?,?,'scooter','zlib-v1',?)", (f"c{k}", rid, start, start + 30_000, b"\x78\x9c\x03\x00\x00\x00\x00\x01"))
        ins("INSERT INTO gap (rideId, kind, startT, endT) VALUES (?, 'scooter', 600000, 660000)", (rid,))
        ins("INSERT INTO stop VALUES (?,?,300000,320000,10.001,-29.999)", (f"st{k}", rid))
    ins("INSERT INTO untracked_distance VALUES ('u1','s1',616.6,619.8,?)", (T0 + 86_400_000,))
    ins("INSERT INTO place VALUES ('p1','Home',10.0,-30.0,NULL,1,12,?)", (T0,))
    ins("INSERT INTO place VALUES ('p2','Work',10.1,-29.97,NULL,0,30,?)", (T0,))
    ins("INSERT INTO route VALUES ('rt1','p1','p2','Home → Work',13700,'ride','saved',?)", (T0,))
    ins("INSERT INTO variant VALUES ('v1','rt1','via the bridge',0,'_p~iF~ps|U',1,0)")
    ins("INSERT INTO choice_point VALUES ('cp1','rt1',10.02,-29.99,10.03,-29.98,2500,NULL)")
    ins("INSERT INTO choice_option VALUES ('co1','cp1','_p~iF',900,'Option A')")
    ins("INSERT INTO ride_option VALUES ('r0','co1',95,3.1,0.4)")
    ins("INSERT INTO climb VALUES ('cl1','rt1',4000,4300,6.5,'Bridge',1,?)", (T0,))
    ins("INSERT INTO ride_climb VALUES ('r0','cl1',40,0.3)")
    ins("INSERT INTO charge VALUES ('ch1','s1','r0','r1',23,100,46.1,54.2,?,?,1,1)", (T0 + 2_000_000, T0 + 3_000_000))
    ins("INSERT INTO calibration VALUES ('ca1','s1',?,'learning',NULL,2,16)", (T0,))
    ins("INSERT INTO wheel_calibration VALUES ('w1',?,512,520,0.985)", (T0,))
    ins("INSERT INTO maintenance_item VALUES ('m1','Check tyres',500,30,586.6,?,NULL)", (T0,))
    ins("INSERT INTO factor_effect (factorId, scope, routeId, level, timeEffectS, usedEffectPct, n, nWithout, confidence, computedAt) VALUES ('W1','trip','rt1','strong',45,1.5,6,14,0.7,?)", (T0,))
    ins("INSERT INTO insight VALUES ('i1','Q1','after','r0','rt1',NULL,'Usual time',5,0.8,?,NULL,NULL,NULL)", (T0,))
    ins("INSERT INTO message_log (type, channel, scheduledFor, sentAt, droppedReason) VALUES ('weekly','notification',?,?,NULL)", (T0, T0))
    ins("INSERT INTO week_summary VALUES (?, '{\"rides\":3}', NULL)", (T0,))
    ins("INSERT INTO weather_hour VALUES ('10.00,-30.00',?,'open-meteo','history',12,270,20,0,24,?)", (T0, T0))
    ins("INSERT INTO elevation_point VALUES ('10.000,-30.000',12,'open-meteo-dem')")
    ins("INSERT INTO fuel_price VALUES ('2000-01',7.12,'auto',?)", (T0,))
    ins("INSERT INTO holiday VALUES ('2000-01-01','holiday','Test holiday','hebcal')")
    ins("INSERT INTO setting VALUES ('units','\"metric\"')")
    ins("INSERT INTO setting VALUES ('packAh','16')")
    ins("INSERT INTO error_log (at, level, source, message, build) VALUES (?, 'info', 'frozen', ?, ?)", (T0, "Frozen database for " + ("1.0" if v10 else "P4"), label))
    if v10:
        # the P5 tables (v2, v3): every one filled with synthetic rows
        ins("INSERT INTO ride_note VALUES ('r0','Synthetic note for Claude',?)", (T0,))
        ins("INSERT INTO feedback (kind, subjectId, subjectText, verdict, reason, note, at) VALUES ('end','r0',NULL,-1,'Ended too early','x',?)", (T0,))
        ins("INSERT INTO prediction (kind, routeId, madeAt, predicted, aux, rideId, actual, settledAt) VALUES ('todayTime','rt1',?,1500,NULL,'r0',1620,?)", (T0, T0 + 1_800_000))
        ins("INSERT INTO shadow_result VALUES ('r0','slow','45','1 warning',0,1)")
        ins("INSERT INTO shadow_result VALUES ('r0','slow','48','0 warnings',1,0)")
        ins("INSERT INTO app_meta VALUES (1,'00000000-0000-0000-0000-0000000F10D1',?,?,'v3',NULL,NULL,?,5)", (label, label, T0))
    else:
        ins("INSERT INTO app_meta VALUES (1,'00000000-0000-0000-0000-00000000F00D','0.4-frozen','0.4-frozen','v1',NULL,NULL,?,3)", (T0,))
    db.commit()
    counts = {t: db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
              for (t,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")}
    db.execute("PRAGMA journal_mode=DELETE")
    db.close()
    empty = [t for t, n in counts.items() if n == 0]
    print(out, f"{out.stat().st_size // 1024} KB", "tables:", len(counts), "empty:", empty)


if __name__ == "__main__":
    main(v10="--v10" in sys.argv)
