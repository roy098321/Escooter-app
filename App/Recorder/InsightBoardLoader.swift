import CorckieCore
import Foundation
import GRDB

// F-21 (P6-4 chunk 3b): loads the stored rides the four insight engines need (Core `SweetSpotInsight`, `DepartureInsight`,
// `CreepInsight`, `WindTodayInsight`) and runs them. Real rides only (no simulated ones); nothing leaves the phone (P-2). Kept in memory
// per ride count and last ride end, so the Stats tab does not reread the readings every time. Compiled into AppTests.
enum InsightBoardLoader {
    struct RideRow: Equatable {
        var id: String
        var routeId: String?
        var startAt: Int64
        var utcOffsetMin: Int
        var distanceM: Double
        var totalS: Double?
        var movingS: Double?
        var usedPct: Double?
        var headwindKmh: Double?
        var windLevel: String?
        var excluded: Bool
    }

    /// The rides the engines look at (newest first, at most 200, real ended rides of 1 km or more)
    static func rides(_ db: AppDatabase) -> [RideRow] {
        (try? db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, routeId, startAt, utcOffsetMin, distanceM, totalS, movingS, COALESCE(usedPctShown, usedPct) AS used, headwindKmh,
                       windLevel, excludedFromUsual
                FROM ride WHERE endAt IS NOT NULL AND kind = 'ride' AND isSimulated = 0 AND distanceM >= 1000
                ORDER BY startAt DESC LIMIT 200
                """).map { r in
                RideRow(id: r["id"], routeId: r["routeId"], startAt: r["startAt"], utcOffsetMin: r["utcOffsetMin"] ?? 0,
                        distanceM: r["distanceM"] ?? 0, totalS: r["totalS"], movingS: r["movingS"], usedPct: r["used"],
                        headwindKmh: r["headwindKmh"], windLevel: r["windLevel"], excluded: (r["excludedFromUsual"] as Int?) == 1)
            }
        }) ?? []
    }

    /// One ride's readings as the sweet spot needs them
    static func speedSamples(_ db: AppDatabase, rideId: String) -> [SpeedSample] {
        (try? db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT t, speedMps, gpsSpeedMps, powerW, voltage, currentA, altBaroM, altFixedM FROM ride_sample WHERE rideId = ? ORDER BY t
                """, arguments: [rideId]).map { r in
                let scooterMps: Double? = r["speedMps"], gpsMps: Double? = r["gpsSpeedMps"]
                let mps = scooterMps ?? gpsMps
                let v: Double? = r["voltage"], a: Double? = r["currentA"], w: Double? = r["powerW"]
                var power = w
                if power == nil, let v, let a { power = v * a }
                let baro: Double? = r["altBaroM"], gps: Double? = r["altFixedM"]
                let alt = baro ?? gps
                return SpeedSample(tS: Double((r["t"] as Int64?) ?? 0) / 1000, speedKmh: mps.map { $0 * 3.6 }, powerW: power, altM: alt)
            }
        }) ?? []
    }

    /// The most ridden saved route of the recent rides (the "usual route")
    static func usualRoute(_ rows: [RideRow], db: AppDatabase) -> RouteRecord? {
        let routes = RouteQueries(db)
        var counts: [String: Int] = [:]
        for r in rows.prefix(60) {
            if let id = r.routeId { counts[id, default: 0] += 1 }
        }
        for (id, _) in counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            if let route = try? routes.route(id: id), route.state == "saved" { return route }
        }
        return nil
    }

    static func placeName(_ id: String?, db: AppDatabase) -> String? {
        id.flatMap { try? RouteQueries(db).place(id: $0) }?.name
    }

    static func reservePct(_ db: AppDatabase) -> Double {
        let ranOut: String? = try? RideQueries(db).setting(key: "t80.batteryRanOut")
        return RealRangeCalc.reservePct(ranOutJson: ranOut)
    }

    static func pctPerKm(_ r: RideRow) -> Double? {
        guard let u = r.usedPct, u > 0, r.distanceM >= 1000 else { return nil }
        return u / (r.distanceM / 1000)
    }

    private static var retired = false

    /// F-21: the stored rows of the retired insight types are removed once per launch (nothing new of them is stored)
    static func retireOldOnce(_ db: AppDatabase) {
        guard !retired, !db.isReadOnly else { return }
        retired = true
        _ = try? InsightQueries(db).retireOld()
    }

    // MARK: the pattern and maintenance insights (Stats)

    private static var cache: (key: String, outcomes: [InsightOutcome])?

    /// The three Stats engines on the stored rides
    static func outcomes(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs()) -> [InsightOutcome] {
        let rows = rides(db)
        let key = "\(ObjectIdentifier(db).hashValue)-\(rows.count)-\(rows.first?.id ?? "")-\(nowMs / OutsideTime.dayMs)"
        if let c = cache, c.key == key { return c.outcomes }
        let offset = rows.first?.utcOffsetMin ?? RouteCardLoader.currentOffsetMin()
        let route = usualRoute(rows, db: db)
        let destination = placeName(route?.toPlaceId, db: db)
        let routeRows = rows.filter { $0.routeId != nil && $0.routeId == route?.id && !$0.excluded }
        let reserve = reservePct(db)
        let calibration = CalibrationUpdater.current(db)

        // speed sweet spot: the last 40 rides of 2 km or more within 120 days
        let since = nowMs - 120 * OutsideTime.dayMs
        let sweetRides = rows.filter { $0.startAt >= since && $0.distanceM >= 2000 }.prefix(40).map { r in
            SweetSpotRide(id: r.id, startAt: r.startAt, distanceKm: r.distanceM / 1000,
                          strongWind: r.windLevel == "strong" || abs(r.headwindKmh ?? 0) >= T.t70WindStrongKmh,
                          samples: speedSamples(db, rideId: r.id))
        }
        let perKm = rows.prefix(T.t85RealRangeRides).compactMap(pctPerKm)
        let ctx = SweetSpotContext(whPerPct: calibration.whPerPct, usualPctPerKm: InsightMath.median(perKm), reservePct: reserve,
                                   destination: destination, routeKm: route?.usualDistanceM.map { $0 / 1000 },
                                   routeTimeS: InsightMath.median(routeRows.compactMap(\.totalS)), utcOffsetMin: offset)
        let sweet = SweetSpotInsight.make(rides: Array(sweetRides), context: ctx)

        // departure time on the usual route
        let departs = routeRows.compactMap { r -> DepartureRide? in
            guard let t = r.totalS, t > 0 else { return nil }
            return DepartureRide(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, totalS: t, distanceKm: r.distanceM / 1000)
        }
        let depart = DepartureInsight.make(rides: departs, destination: destination, utcOffsetMin: offset)

        // battery-use creep on the saved routes
        let creepRides = rows.compactMap { r -> CreepRide? in
            guard let route = r.routeId, !r.excluded, let y = pctPerKm(r), let moving = r.movingS ?? r.totalS, moving > 0 else { return nil }
            return CreepRide(id: r.id, startAt: r.startAt, routeId: route, pctPerKm: y, speedKmh: r.distanceM / 1000 / (moving / 3600),
                             headwindKmh: r.headwindKmh, distanceKm: r.distanceM / 1000)
        }
        let creep = CreepInsight.make(rides: creepRides, reservePct: reserve, utcOffsetMin: offset)

        let out = [sweet, depart, creep]
        cache = (key, out)
        return out
    }

    static func board(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs()) -> InsightBoard {
        let all = outcomes(db, nowMs: nowMs)
        var board = InsightBoard.make(all)
        // Note 9: progress cards and graduated pages; the last range width per insight is kept to say when it widened
        let key = "corckie.note9.rangeWidths"
        let before = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let made = InsightProgressBuilder.make(all, previousWidths: before)
        board.progress = made.progress
        board.pages = made.pages
        if made.widths != before { UserDefaults.standard.set(made.widths, forKey: key) }
        return board
    }

    // MARK: today's wind (Home)

    /// The route today's likely ride takes: the chosen one, else the saved route whose usual departure (same kind of day) is next
    /// within the coming 12 hours.
    static func likelyRoute(_ db: AppDatabase, rows: [RideRow], chosenRouteId: String?, nowMs: Int64, utcOffsetMin: Int)
        -> (route: RouteRecord, departMs: Int64)? {
        let routes = RouteQueries(db)
        let day = OutsideTime.dayMs
        let localNow = nowMs + Int64(utcOffsetMin) * 60_000
        let nowMinute = Double((localNow % day) / 60_000)
        let weekday = ((localNow / day) + 4) % 7          // 0 = Sunday (1 Jan 1970 was a Thursday)
        let weekend = weekday == 5 || weekday == 6        // Friday and Saturday off (Israel)
        if let id = chosenRouteId, let route = try? routes.route(id: id) { return (route, nowMs) }
        var best: (route: RouteRecord, departMs: Int64)?
        var bestWait = Double.infinity
        var byRoute: [String: [Double]] = [:]
        for r in rows where r.routeId != nil {
            let local = r.startAt + Int64(r.utcOffsetMin) * 60_000
            let wd = ((local / day) + 4) % 7
            guard (wd == 5 || wd == 6) == weekend else { continue }
            byRoute[r.routeId ?? "", default: []].append(Double((local % day) / 60_000))
        }
        for (id, minutes) in byRoute where minutes.count >= 5 {
            guard let usual = InsightMath.median(minutes) else { continue }
            let wait = usual - nowMinute
            guard wait >= -30, wait <= 12 * 60, wait < bestWait, let route = try? routes.route(id: id), route.state == "saved" else { continue }
            bestWait = wait
            best = (route, nowMs + Int64(max(0, wait) * 60_000))
        }
        return best
    }

    /// Today's wind card for Home, or nil when it does not matter (or is not sure enough)
    static func today(_ db: AppDatabase, chosenRouteId: String?, nowMs: Int64 = FactorUpdater.nowMs(),
                      utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> InsightCard? {
        let rows = rides(db)
        guard let likely = likelyRoute(db, rows: rows, chosenRouteId: chosenRouteId, nowMs: nowMs, utcOffsetMin: utcOffsetMin) else { return nil }
        let route = likely.route, departMs = likely.departMs
        let routeRows = rows.filter { $0.routeId == route.id && !$0.excluded }
        let todayS = InsightMath.median(routeRows.compactMap(\.totalS)) ?? 900
        guard let hw = InsightRunner.forecastHeadwind(db, routeId: route.id, todayS: todayS, nowMs: departMs), hw > 0 else { return nil }
        // the wind at the departure hour, for the line under the card
        let variants = (try? RouteQueries(db).variants(routeId: route.id)) ?? []
        let path = Geo.decode((variants.first { $0.isReference } ?? variants.first)?.polyline ?? "")
        var windKmh = hw, fromDeg: Double?
        if let p = path.first {
            let rowsW = (try? OutsideQueries(db).weather(cell: GeoCell.key(lat: p.lat, lon: p.lon), from: OutsideTime.floorHour(departMs),
                                                          to: OutsideTime.floorHour(departMs) + OutsideTime.hourMs, kind: .forecast)) ?? []
            if let w = rowsW.first {
                windKmh = w.windKmh
                fromDeg = w.windFromDeg
            }
        }
        let history = rows.compactMap { r -> WindRide? in
            guard let h = r.headwindKmh, let y = pctPerKm(r) else { return nil }
            return WindRide(startAt: r.startAt, headwindKmh: h, pctPerKm: y, distanceKm: r.distanceM / 1000)
        }
        let routeKm = (route.usualDistanceM ?? InsightMath.median(routeRows.map(\.distanceM)) ?? 0) / 1000
        guard routeKm > 0 else { return nil }
        let used = InsightMath.median(routeRows.compactMap(\.usedPct)) ?? (InsightMath.median(history.map(\.pctPerKm)) ?? 0) * routeKm
        let localDepart = departMs + Int64(utcOffsetMin) * 60_000
        let today = WindToday(routeTitle: RouteService.title(routeId: route.id, database: db), fromName: placeName(route.fromPlaceId, db: db),
                              toName: placeName(route.toPlaceId, db: db), headwindKmh: hw, windKmh: windKmh, windFromDeg: fromDeg,
                              departureMinute: Double((localDepart % OutsideTime.dayMs) / 60_000), routeKm: routeKm, usualUsedPct: used,
                              reservePct: reservePct(db))
        return WindTodayInsight.make(history: history, today: today, utcOffsetMin: utcOffsetMin).shown
    }
}
