import Foundation

/// Migration v1: the whole DATA_MODEL §2 schema (foundation build 0.4).
/// Rules (DATA_MODEL §4): append-only and additive; never edit this SQL once a build with it
/// has been installed. Changes go in Migration0002 and later.
/// Tools/make_frozen_db.py reads the SQL between the markers to build the frozen test database.
enum Migration0001 {
    static let identifier = "v1"

    static let sql = #"""
-- SQL-BEGIN v1
CREATE TABLE scooter (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT, peripheralId TEXT, firstSeenAt INTEGER, odometerAtFirstKm REAL,
  chip TEXT, firmware TEXT, software TEXT, gearCaps TEXT, forgottenAt INTEGER
);
CREATE TABLE ride (
  id TEXT PRIMARY KEY NOT NULL,
  scooterId TEXT REFERENCES scooter(id),
  kind TEXT NOT NULL DEFAULT 'ride', status TEXT NOT NULL DEFAULT 'recording',
  startAt INTEGER NOT NULL, endAt INTEGER, firstMoveAt INTEGER, lastMoveAt INTEGER, utcOffsetMin INTEGER,
  endReason TEXT, trimStartAt INTEGER, trimEndAt INTEGER, mergeGroupId TEXT,
  loadLevel TEXT, loadKg REAL, routeId TEXT, variantId TEXT, startPlaceId TEXT, endPlaceId TEXT,
  assignedByHand INTEGER NOT NULL DEFAULT 0,
  distanceM REAL, totalS REAL, movingS REAL, avgMovingMps REAL, topSpeedMps REAL, stops INTEGER,
  energyWhRaw REAL, energyWhCal REAL, usedPct REAL, usedPctMethod TEXT,
  startRestPct REAL, startRestV REAL, endRestPct REAL, endRestV REAL, odoStartKm REAL, odoEndKm REAL,
  elevGainM REAL, elevLossM REAL, elevProvisional INTEGER, tempStartC REAL, tempPeakC REAL, tempRiseC REAL,
  gearShare TEXT, timeAtMaxPct REAL, downhillTopMps REAL, fullThrottleAccelPct REAL, fullThrottleMaxPct REAL,
  gapScooterS REAL, gapGpsS REAL, ignoredReadings INTEGER NOT NULL DEFAULT 0, hasGps INTEGER,
  headwindKmh REAL, windLevel TEXT, wet TEXT, wetOverride TEXT, rushHour INTEGER, dayType TEXT,
  airTempC REAL, holidayWeek INTEGER,
  excludedFromUsual INTEGER NOT NULL DEFAULT 0, promptAnswer TEXT,
  isSimulated INTEGER NOT NULL DEFAULT 0, calcVersion INTEGER NOT NULL DEFAULT 1,
  decoderVersion INTEGER NOT NULL DEFAULT 1, createdBuild TEXT
);
CREATE INDEX ride_startAt ON ride(startAt);
CREATE TABLE ride_sample (
  rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE,
  t INTEGER NOT NULL,
  speedMps REAL, gpsSpeedMps REAL, lat REAL, lon REAL, hAccM REAL, courseDeg REAL,
  altBaroM REAL, altFixedM REAL, voltage REAL, currentA REAL, powerW REAL, batteryPct INTEGER,
  tempC REAL, gear INTEGER, capKmh INTEGER, brake INTEGER, light INTEGER, odometerKm REAL,
  mode TEXT, moving INTEGER, stopId TEXT, distanceM REAL,
  PRIMARY KEY (rideId, t)
);
CREATE TABLE raw_chunk (
  id TEXT PRIMARY KEY NOT NULL,
  rideId TEXT REFERENCES ride(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL, startAt INTEGER NOT NULL, endAt INTEGER NOT NULL,
  kind TEXT NOT NULL, codec TEXT NOT NULL DEFAULT 'zlib-v1', blob BLOB NOT NULL
);
CREATE INDEX raw_chunk_ride ON raw_chunk(rideId, seq);
CREATE TABLE gap (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, startT INTEGER NOT NULL, endT INTEGER
);
CREATE TABLE stop (
  id TEXT PRIMARY KEY NOT NULL,
  rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE,
  startT INTEGER NOT NULL, endT INTEGER, lat REAL, lon REAL
);
CREATE TABLE untracked_distance (
  id TEXT PRIMARY KEY NOT NULL, scooterId TEXT, fromOdoKm REAL, toOdoKm REAL, detectedAt INTEGER
);
CREATE TABLE place (
  id TEXT PRIMARY KEY NOT NULL, name TEXT, lat REAL NOT NULL, lon REAL NOT NULL, radiusM REAL,
  canCharge INTEGER NOT NULL DEFAULT 0, learnedAltM REAL, createdAt INTEGER
);
CREATE TABLE route (
  id TEXT PRIMARY KEY NOT NULL, fromPlaceId TEXT, toPlaceId TEXT, name TEXT, usualDistanceM REAL,
  sizeClass TEXT, state TEXT NOT NULL DEFAULT 'suggested', createdAt INTEGER
);
CREATE TABLE variant (
  id TEXT PRIMARY KEY NOT NULL, routeId TEXT REFERENCES route(id) ON DELETE CASCADE,
  name TEXT, nameByHand INTEGER NOT NULL DEFAULT 0, polyline TEXT,
  isReference INTEGER NOT NULL DEFAULT 0, isCombination INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE choice_point (
  id TEXT PRIMARY KEY NOT NULL, routeId TEXT REFERENCES route(id) ON DELETE CASCADE,
  splitLat REAL, splitLon REAL, rejoinLat REAL, rejoinLon REAL, posOnRefM REAL, sideTag TEXT
);
CREATE TABLE choice_option (
  id TEXT PRIMARY KEY NOT NULL, choicePointId TEXT REFERENCES choice_point(id) ON DELETE CASCADE,
  polyline TEXT, lengthM REAL, name TEXT
);
CREATE TABLE ride_option (
  rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE, optionId TEXT NOT NULL,
  timeS REAL, energyWh REAL, usedPct REAL,
  PRIMARY KEY (rideId, optionId)
);
CREATE TABLE climb (
  id TEXT PRIMARY KEY NOT NULL, routeId TEXT REFERENCES route(id) ON DELETE CASCADE,
  startPosM REAL, endPosM REAL, gainM REAL, name TEXT, pinned INTEGER NOT NULL DEFAULT 0, firstSeenAt INTEGER
);
CREATE TABLE ride_climb (
  rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE, climbId TEXT NOT NULL,
  timeS REAL, usedPct REAL,
  PRIMARY KEY (rideId, climbId)
);
CREATE TABLE charge (
  id TEXT PRIMARY KEY NOT NULL, scooterId TEXT, afterRideId TEXT, beforeRideId TEXT,
  fromPct REAL, toPct REAL, fromV REAL, toV REAL, windowStartAt INTEGER, windowEndAt INTEGER,
  inferredWhileAway INTEGER NOT NULL DEFAULT 1, startedByShutdownFlag INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE calibration (
  id TEXT PRIMARY KEY NOT NULL, scooterId TEXT, startedAt INTEGER, status TEXT NOT NULL DEFAULT 'learning',
  factor REAL, ridesUsed INTEGER NOT NULL DEFAULT 0, packAh REAL
);
CREATE TABLE wheel_calibration (
  id TEXT PRIMARY KEY NOT NULL, stretchAt INTEGER, gpsM REAL, wheelM REAL, factor REAL
);
CREATE TABLE maintenance_item (
  id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, intervalKm REAL, intervalDays REAL,
  lastDoneOdoKm REAL, lastDoneAt INTEGER, notifiedAt INTEGER
);
CREATE TABLE factor_effect (
  id INTEGER PRIMARY KEY AUTOINCREMENT, factorId TEXT NOT NULL, scope TEXT, routeId TEXT, level TEXT,
  timeEffectS REAL, usedEffectPct REAL, n INTEGER, nWithout INTEGER, confidence REAL, computedAt INTEGER
);
CREATE TABLE insight (
  id TEXT PRIMARY KEY NOT NULL, type TEXT NOT NULL, moment TEXT, rideId TEXT, routeId TEXT, weekStart INTEGER,
  text TEXT, basedOnN INTEGER, score REAL, createdAt INTEGER, shownAt INTEGER, dismissedAt INTEGER, expiresAt INTEGER
);
CREATE TABLE message_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, channel TEXT, scheduledFor INTEGER, sentAt INTEGER, droppedReason TEXT
);
CREATE TABLE week_summary (
  weekStart INTEGER PRIMARY KEY NOT NULL, json TEXT, notifiedAt INTEGER
);
CREATE TABLE weather_hour (
  cellKey TEXT NOT NULL, hourAt INTEGER NOT NULL, source TEXT, kind TEXT NOT NULL DEFAULT 'forecast',
  windKmh REAL, windFromDeg REAL, gustKmh REAL, precipMm REAL, airTempC REAL, fetchedAt INTEGER,
  PRIMARY KEY (cellKey, hourAt, kind)
);
CREATE TABLE elevation_point (
  cellKey TEXT PRIMARY KEY NOT NULL, altM REAL, source TEXT
);
CREATE TABLE fuel_price (
  month TEXT PRIMARY KEY NOT NULL, priceIls REAL, source TEXT, fetchedAt INTEGER
);
CREATE TABLE holiday (
  date TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, source TEXT,
  PRIMARY KEY (date, name)
);
CREATE TABLE setting (
  key TEXT PRIMARY KEY NOT NULL, json TEXT
);
CREATE TABLE error_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, level TEXT NOT NULL, source TEXT NOT NULL,
  message TEXT NOT NULL, build TEXT
);
CREATE INDEX error_log_at ON error_log(at);
CREATE TABLE app_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1), installId TEXT NOT NULL, createdBuild TEXT, lastBuild TEXT,
  lastMigration TEXT, lastFullBackupAt INTEGER, lastBackupAt INTEGER, createdAt INTEGER, launchCount INTEGER NOT NULL DEFAULT 0
);
-- SQL-END v1
"""#

    /// Every table v1 creates (the migration test checks they all exist).
    static let tables = [
        "scooter", "ride", "ride_sample", "raw_chunk", "gap", "stop", "untracked_distance",
        "place", "route", "variant", "choice_point", "choice_option", "ride_option", "climb", "ride_climb",
        "charge", "calibration", "wheel_calibration", "maintenance_item",
        "factor_effect", "insight", "message_log", "week_summary",
        "weather_hour", "elevation_point", "fuel_price", "holiday",
        "setting", "error_log", "app_meta"
    ]
}
