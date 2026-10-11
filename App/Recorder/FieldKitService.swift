import CorckieCore
import Foundation

/// T-00 part 2: the glue between the stored tables (App/Store) and the Core rules (`PredictionSettler`, `AccuracyCalc`, `ShadowCalc`).
/// Nothing here changes what the app does: it only writes down what was shown and what happened. Every call is safe to fail.
enum FieldKitService {
    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Logging what is shown

    /// Today's time and battery for a route (route card, Where to? chip).
    static func logToday(_ db: AppDatabase, routeId: String, rides: [RouteRideStats], nowMs: Int64, utcOffsetMin: Int, departureMinute: Int? = nil) {
        guard !db.isReadOnly, case .estimate(let e) = TodayEstimator.estimate(rides: rides, nowMs: nowMs, utcOffsetMin: utcOffsetMin,
                                                                               departureMinute: departureMinute) else { return }
        let store = PredictionQueries(db)
        _ = try? store.log(kind: PredictionKind.time, routeId: routeId, predicted: e.timeS, at: nowMs)
        if let u = e.usedPct { _ = try? store.log(kind: PredictionKind.battery, routeId: routeId, predicted: u, at: nowMs) }
    }

    /// The there-and-back card: the battery % expected at the destination (battery now minus the way there).
    static func logThereBack(_ db: AppDatabase, routeId: String, rides: [RouteRideStats], battery: BatteryNow?, shown: ThereAndBackModel?,
                             nowMs: Int64, utcOffsetMin: Int) {
        guard !db.isReadOnly, shown != nil, let battery, (battery.ageMin ?? 0) <= 30,
              case .estimate(let e) = TodayEstimator.estimate(rides: rides, nowMs: nowMs, utcOffsetMin: utcOffsetMin), let used = e.usedPct else { return }
        _ = try? PredictionQueries(db).log(kind: PredictionKind.thereBack, routeId: routeId, predicted: battery.pct - used, at: nowMs)
    }

    /// At ride start: the real range and the Wh per 1% the calibration uses.
    static func logRideStart(_ db: AppDatabase, currentPct: Double?, connected: Bool, nowMs: Int64 = FieldKitService.nowMs()) {
        guard !db.isReadOnly else { return }
        let overview = BatteryOverview.load(db, currentPct: currentPct, connected: connected)
        let store = PredictionQueries(db)
        if let r = overview.range {
            _ = try? store.log(kind: PredictionKind.range, routeId: nil, predicted: r.rangeKm, aux: max(0, r.currentPct - r.reservePct), at: nowMs)
        }
        _ = try? store.log(kind: PredictionKind.calib, routeId: nil, predicted: overview.calibration.whPerPct, at: nowMs)
    }

    /// The arrival times shown at 25 / 50 / 75% of a followed ride (epoch ms).
    static func logEta(_ db: AppDatabase, routeId: String?, marks: [EtaMark]) {
        guard !db.isReadOnly else { return }
        let store = PredictionQueries(db)
        for m in marks {
            _ = try? store.log(kind: PredictionKind.eta(percent: m.percent), routeId: routeId, predicted: m.arrivalS * 1000,
                               at: Int64(m.atS * 1000))
        }
    }

    // MARK: After a ride

    /// Settles the predictions of a closed ride and works out its shadow decisions. Real rides only.
    static func afterRide(_ db: AppDatabase, rideId: String, nowMs: Int64 = FieldKitService.nowMs()) throws {
        let store = PredictionQueries(db)
        guard let f = try store.facts(rideId: rideId), !f.isSimulated, f.kind == "ride", f.status != "recording", let endAt = f.endAt else { return }
        let waiting = try store.waiting().map { p in
            OpenPrediction(id: p.id, kind: p.kind, routeId: p.routeId, madeAt: p.madeAt, predicted: p.predicted, aux: p.aux)
        }
        let ride = SettledRide(id: f.id, routeId: f.routeId, startAt: f.startAt, endAt: endAt, lastMoveAt: f.lastMoveAt, totalS: f.totalS,
                               distanceM: f.distanceM, usedPct: f.usedPct, startRestPct: f.startRestPct, endRestPct: f.endRestPct,
                               energyWhRaw: f.energyWhRaw)
        let result = PredictionSettler.settle(open: waiting, ride: ride)
        for s in result.settled { try store.settle(id: s.predictionId, rideId: rideId, actual: s.actual, at: nowMs) }
        try store.delete(ids: result.dropIds)
        try store.prune(now: nowMs, olderThanMs: PredictionSettler.expiryMs)
        try shadow(db, facts: f)
    }

    /// Shadow thresholds for one ride, from its stored 5-second samples.
    static func shadow(_ db: AppDatabase, facts f: PredictionRideFacts) throws {
        let samples = try RideQueries(db).samples(rideId: f.id).map { s in
            ShadowSample(t: Double(s.t) / 1000, scooter: (s.mode ?? "scooter") == "scooter",
                         scooterKmh: s.speedMps.map { $0 * 3.6 }, gpsKmh: s.gpsSpeedMps.map { $0 * 3.6 })
        }
        var route: ShadowCalc.RouteHistory?
        if let others = try PredictionQueries(db).otherRidesOnRoute(rideId: f.id) {
            route = ShadowCalc.RouteHistory(otherTotalS: others.otherTotalS, otherUsedPct: others.otherUsedPct)
        }
        let decisions = ShadowCalc.evaluate(samples: samples, thisTotalS: f.totalS, thisUsedPct: f.usedPct, route: route)
        try PredictionQueries(db).replaceShadow(rideId: f.id, rows: decisions.map {
            (rule: $0.rule, variant: $0.variant, decision: $0.decision, differs: $0.differs, isStandard: $0.isStandard)
        })
    }

    // MARK: Read back

    static func accuracyRows(_ db: AppDatabase) -> [PredictionRow] {
        ((try? PredictionQueries(db).all()) ?? []).map {
            PredictionRow(kind: $0.kind, predicted: $0.predicted, actual: $0.actual, madeAt: $0.madeAt)
        }
    }

    static func accuracyLines(_ db: AppDatabase) -> [AccuracyLine] { AccuracyCalc.lines(accuracyRows(db)) }

    /// accuracy.txt
    static func accuracyText(_ db: AppDatabase?, now: Date = Date()) -> String {
        guard let db else { return "Accuracy: (database not open)\n" }
        return AccuracyCalc.text(accuracyRows(db), now: now.formatted())
    }

    /// shadow.txt
    static func shadowText(_ db: AppDatabase?, now: Date = Date()) -> String {
        guard let db else { return "Shadow thresholds: (database not open)\n" }
        let rows = ((try? PredictionQueries(db).shadowRows()) ?? []).map {
            ShadowRow(startAt: $0.startAt, rule: $0.rule, variant: $0.variant, decision: $0.decision, differs: $0.differs, isStandard: $0.isStandard)
        }
        return ShadowCalc.text(rows, now: now.formatted())
    }

    // MARK: Scenario list (P6 group in Checks)

    /// Reads the rides and the marks the app noted, and returns the passing verdicts.
    static func scenarioVerdicts(_ db: AppDatabase) -> [RideCheckVerdict] {
        let store = PredictionQueries(db)
        guard let rows = try? store.scenarioRows() else { return [] }
        let rides = rows.map { r in
            ScenarioRide(id: r.id, startAtMs: r.startAt, endAtMs: r.endAt, utcOffsetMin: r.utcOffsetMin, totalS: r.totalS, distanceM: r.distanceM,
                         startPct: r.startPct, wet: r.wet, gapGpsS: r.gapGpsS, hasGps: r.hasGps, loadKg: r.loadKg, loadLevel: r.loadLevel,
                         firstOnItsRoute: r.firstOnItsRoute, endReason: r.endReason)
        }
        let marks = ScenarioMarks(lowPowerAt: RideMarks.list(db, RideMarks.lowPower), screenOnAt: RideMarks.list(db, RideMarks.screenOn),
                                  screenTrackingSince: RideMarks.list(db, RideMarks.trackingSince).first,
                                  chargedAfterRideIds: (try? store.chargedAfterRideIds()) ?? [])
        return ScenarioRules.evaluate(rides, marks: marks)
    }
}

/// Moments noted while rides are on (Low Power Mode, screen on), kept in `setting` as small JSON lists of epoch ms.
/// The most recent 200 of each are kept.
enum RideMarks {
    static let lowPower = "p6.marks.lowPower"
    static let screenOn = "p6.marks.screenOn"
    static let trackingSince = "p6.marks.trackingSince"
    static let keep = 200

    static func list(_ db: AppDatabase, _ key: String) -> [Int64] {
        guard let json = try? RideQueries(db).setting(key: key), let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([Int64].self, from: data) else { return [] }
        return values
    }

    /// Adds a mark (a mark within a minute of the last one is not added again, so a ride writes a few lines at most).
    static func add(_ db: AppDatabase, _ key: String, at ms: Int64) {
        guard !db.isReadOnly else { return }
        var values = list(db, key)
        if let last = values.last, ms - last < 60_000 { return }
        values.append(ms)
        if values.count > keep { values.removeFirst(values.count - keep) }
        guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else { return }
        try? RideQueries(db).setSetting(key: key, json: json)
    }

    /// The first time screen tracking ran (rides before it cannot be called "screen off").
    static func noteTrackingStarted(_ db: AppDatabase, at ms: Int64) {
        guard list(db, trackingSince).isEmpty, !db.isReadOnly else { return }
        try? RideQueries(db).setSetting(key: trackingSince, json: "[\(ms)]")
    }
}
