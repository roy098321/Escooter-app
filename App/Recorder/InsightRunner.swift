import CorckieCore
import Foundation

// M4-03: runs the insight catalogue (Core `InsightCatalogue`) on the stored rides and keeps the `insight` rows (CALC_SPEC 9.1):
// - after ride: from the Recorder close hook, after `FactorUpdater` (also for recovered rides);
// - weather arrives: `FactorUpdater.refreshPending` → `weatherArrived` re-runs the rides it filled; a card for an already seen
//   summary goes to Recent insights only;
// - ride start: `atRideStart` (Q9 the M2-09 warning, Q1 destination guess, Q2 tight battery, Q15 headwind): candidates with
//   their C24 priority, at most 2 picked (M4-04 decides what is sent);
// - weekly: at each ride end and app open, the running and the last finished week (Q22, Q4-weekly, Q13-weekly).
// Generators only produce candidates; `InsightDedupe` keeps one row per id, once-only rows once, cooldowns.
// Compiled into AppTests with App/Store and App/Routes.

enum InsightRunner {
    struct Report: Equatable {
        var made = 0
        var inserted = 0
        var updated = 0
        var progress = 0

        var text: String { "Insights: \(made) made, \(inserted) new, \(updated) updated, \(progress) progress lines" }
    }

    static func nowMs() -> Int64 { FactorUpdater.nowMs() }

    // MARK: After ride

    /// All after-ride insights of one ride, merged into `insight`.
    @discardableResult
    static func afterRide(_ database: AppDatabase, rideId: String, nowMs: Int64 = nowMs()) throws -> Report {
        guard !database.isReadOnly else { return Report() }
        let store = InsightQueries(database)
        let candidates = try candidatesAfterRide(database, rideId: rideId, nowMs: nowMs)
        let existing = try store.existing(forRide: rideId)
        let merge = InsightDedupe.merge(candidates: candidates, existing: existing, nowMs: nowMs, summarySeen: try store.summarySeen(rideId: rideId))
        let keep = Set(candidates.filter(\.isProgress).map(\.id))
        try store.save(merge, rideId: rideId, keepProgress: keep)
        return Report(made: candidates.count, inserted: merge.insert.count, updated: merge.update.count,
                      progress: candidates.filter(\.isProgress).count)
    }

    /// Weather arrived for these rides (pattern W filled): their factor insights again.
    @discardableResult
    static func weatherArrived(_ database: AppDatabase, rideIds: [String], nowMs: Int64 = nowMs()) -> Report {
        var total = Report()
        for id in rideIds {
            guard let r = try? afterRide(database, rideId: id, nowMs: nowMs) else { continue }
            total.made += r.made
            total.inserted += r.inserted
            total.updated += r.updated
            total.progress += r.progress
        }
        return total
    }

    static func candidatesAfterRide(_ database: AppDatabase, rideId: String, nowMs: Int64) throws -> [Insight] {
        let q = InsightQueries(database)
        guard let ride = try q.ride(rideId), ride.endAt != nil, ride.kind != "discarded" else { return [] }
        var out: [Insight] = []
        let routes = RouteQueries(database)
        let calibration = CalibrationUpdater.current(database)
        let realRides = try q.endedRideCount(simulated: ride.isSimulated)

        // M4-06: heat (M38): the Peak card for any ride; hot day / ran hotter on a saved route (5 rides or more)
        func heat(_ forRoute: String?) -> [Insight] {
            let others = forRoute.flatMap { try? SmartPromptQueries(database).heatRides(routeId: $0, excluding: rideId, simulated: ride.isSimulated) } ?? []
            return InsightCatalogue.heatAfter(rideId: rideId, routeId: forRoute, peakC: ride.tempPeakC,
                                              ride: HeatRide(riseC: ride.tempRiseC, distanceKm: (ride.distanceM ?? 0) / 1000, airTempC: ride.airTempC),
                                              routeRides: others.map { HeatRide(riseC: $0.riseC, distanceKm: ($0.distanceM ?? 0) / 1000, airTempC: $0.airTempC) },
                                              nowMs: nowMs)
        }
        guard let routeId = ride.routeId, let route = try routes.route(id: routeId), route.state == "saved" else {
            out += InsightCatalogue.firstAndUnlock(rideId: rideId, realRides: realRides, routeId: nil, routeName: nil, routeRides: 0,
                                                   routeBatteryRides: 0, calibratedNow: !ride.isSimulated && calibration.status == .calibrated,
                                                   whPerPct: calibration.whPerPct, firstRangeKm: nil, nowMs: nowMs)
            return out + heat(nil)
        }
        let name = RouteService.title(routeId: routeId, database: database)
        let rows = (try? routes.routeRides(routeId: routeId)) ?? []
        let stats = RouteCardLoader.stats(rows.filter { $0.kind == "ride" })
        let others = UsualRange.select(stats.filter { $0.rideId != rideId }, nowMs: nowMs)
        let variants = insightVariants(database, routeId: routeId, stats: UsualRange.select(stats, nowMs: nowMs))
        let explanation = FactorEffects.forRide(database, rideId: rideId, nowMs: nowMs)
        let routeEffects = FactorEffects.forRoute(database, routeId: routeId)
        let pooled = ride.isSimulated ? [] : FactorEffects.forPooled(database)

        // first / unlock
        let usable = stats.filter { !$0.excluded }
        out += InsightCatalogue.firstAndUnlock(rideId: rideId, realRides: realRides, routeId: routeId, routeName: name,
                                               routeRides: usable.filter { $0.totalS != nil }.count,
                                               routeBatteryRides: usable.filter { $0.usedPct != nil }.count,
                                               calibratedNow: !ride.isSimulated && calibration.status == .calibrated,
                                               whPerPct: calibration.whPerPct, firstRangeKm: nil, nowMs: nowMs)
        // Q1 / Q2 / Q18 (variants)
        out += InsightCatalogue.q1q2After(rideId: rideId, routeId: routeId, rideVariantId: ride.variantId, rideTimeS: ride.totalS, variants: variants, nowMs: nowMs)
        out += InsightCatalogue.q18(rideId: rideId, routeId: routeId, variants: variants, nowMs: nowMs)
        // Q3 (choice points)
        for o in (try? q.optionTimes(rideId: rideId)) ?? [] {
            out += InsightCatalogue.q3(rideId: rideId, routeId: routeId, optionId: o.optionId, optionName: o.name ?? "shortcut",
                                       rideOptionTimeS: o.rideTimeS, optionTimesS: o.optionTimesS, otherTimesS: o.otherTimesS, nowMs: nowMs)
        }
        // Q4 (noticeably different + causes)
        out += InsightCatalogue.q4After(rideId: rideId, routeId: routeId, rideTimeS: ride.totalS, rideUsedPct: ride.usedPct,
                                        usualTime: UsualRange.range(of: .time, rides: others), usualUsed: UsualRange.range(of: .battery, rides: others),
                                        explanation: explanation, nowMs: nowMs)
        // Q13 (time at max, when M20 fills it)
        out += InsightCatalogue.q13After(rideId: rideId, routeId: routeId, routeName: name, rides: (try? q.capRides(routeId: routeId)) ?? [], nowMs: nowMs)
        // Q15 (wind credit / progress)
        out += InsightCatalogue.q15After(rideId: rideId, routeId: routeId, routeName: name, rideHeadwindKmh: ride.headwindKmh, explanation: explanation,
                                         routeEffects: routeEffects, nowMs: nowMs)
        // Q17 (new climbs during this ride)
        for c in (try? q.newClimbs(routeId: routeId, from: ride.startAt, to: (ride.endAt ?? ride.startAt) + 10 * 60_000)) ?? [] {
            out += InsightCatalogue.q17New(rideId: rideId, routeId: routeId, climbId: c.id, climbName: c.name, gainM: c.gainM, nowMs: nowMs)
        }
        // Q19 (load)
        out += InsightCatalogue.q19After(rideId: rideId, routeId: routeId, loadKg: ride.loadKg, loadLevel: ride.loadLevel,
                                         rideKm: (ride.distanceM ?? 0) / 1000, pooledEffects: pooled, nowMs: nowMs)
        return out + heat(routeId)
    }

    /// The route's variants with their recent rides (the usual-range selection: 90 days, newest 20, not excluded)
    static func insightVariants(_ database: AppDatabase, routeId: String, stats: [RouteRideStats]) -> [InsightVariant] {
        let records = (try? RouteQueries(database).variants(routeId: routeId)) ?? []
        return records.map { v -> InsightVariant in
            let mine = stats.filter { $0.variantId == v.id }
            return InsightVariant(id: v.id, name: v.name ?? "Variant", timesS: mine.compactMap(\.totalS), usedPct: mine.compactMap(\.usedPct),
                                  gainM: mine.compactMap(\.elevGainM), distanceM: mine.compactMap(\.distanceM))
        }
    }

    // MARK: Ride start

    /// The ride-start candidates for the followed (or guessed) route, stored as `start` rows; returns the 2 picked by C24 order
    /// (shown) and the rest (to the summary). Q9's text is the one the live view shows (M2-09).
    static func atRideStart(_ database: AppDatabase, routeId selected: String?, battery: BatteryNow?, lat: Double?, lon: Double?,
                            rideId: String? = nil, nowMs: Int64 = nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin())
        -> (shown: [Insight], toSummary: [Insight]) {
        let candidates = startCandidates(database, routeId: selected, battery: battery, lat: lat, lon: lon, rideId: rideId, nowMs: nowMs,
                                         utcOffsetMin: utcOffsetMin)
        if !database.isReadOnly, !candidates.isEmpty {
            let store = InsightQueries(database)
            let existing = (try? store.existing(forRide: rideId)) ?? []
            try? store.save(InsightDedupe.merge(candidates: candidates, existing: existing, nowMs: nowMs, summarySeen: false))
        }
        return InsightRanking.startPick(candidates)
    }

    static func startCandidates(_ database: AppDatabase, routeId selected: String?, battery: BatteryNow?, lat: Double?, lon: Double?,
                                rideId: String?, nowMs: Int64, utcOffsetMin: Int) -> [Insight] {
        let routes = RouteQueries(database)
        var out: [Insight] = []
        var routeId = selected
        // Q1-live: no route picked, a confident destination guess from the start place
        if routeId == nil, let lat, let lon {
            let places = ((try? routes.places()) ?? []).map {
                PlaceInfo(id: $0.id, name: $0.name, point: GeoPoint(lat: $0.lat, lon: $0.lon), radiusM: $0.radiusM, canCharge: $0.canCharge)
            }
            if let place = PlaceMatcher.nearest(to: GeoPoint(lat: lat, lon: lon), in: places, tripLengthM: 5_000) {
                var rides: [DestinationRide] = []
                for r in ((try? routes.routes()) ?? []) where r.state == "saved" && r.fromPlaceId == place.id {
                    for x in (try? routes.routeRides(routeId: r.id)) ?? [] where x.kind == "ride" {
                        rides.append(DestinationRide(routeId: r.id, startPlaceId: place.id, startAt: x.startAt, utcOffsetMin: x.utcOffsetMin ?? 0))
                    }
                }
                if let guess = InsightCatalogue.destinationGuess(rides: rides, startPlaceId: place.id, nowMs: nowMs, utcOffsetMin: utcOffsetMin) {
                    routeId = guess.routeId
                    let stats = UsualRange.select(RouteCardLoader.stats((try? routes.routeRides(routeId: guess.routeId)) ?? []), nowMs: nowMs)
                    let to = (try? routes.route(id: guess.routeId))?.toPlaceId.flatMap { try? routes.place(id: $0) }?.name
                    out += InsightCatalogue.q1Live(guess: guess, destination: to ?? RouteService.title(routeId: guess.routeId, database: database),
                                                   variants: insightVariants(database, routeId: guess.routeId, stats: stats),
                                                   todayS: Geo.median(stats.compactMap(\.totalS)), rideId: rideId, nowMs: nowMs)
                }
            }
        }
        guard let routeId, let route = try? routes.route(id: routeId) else { return out }
        let rows = (try? routes.routeRides(routeId: routeId)) ?? []
        let stats = UsualRange.select(RouteCardLoader.stats(rows.filter { $0.kind == "ride" }), nowMs: nowMs)
        // Q9: the M2-09 there-and-back warning (decision with the 10% margin), folded in as a row
        if let battery, let input = RouteCardLoader.cardInput(routeId: routeId, database: database, nowMs: nowMs, utcOffsetMin: utcOffsetMin, battery: battery) {
            out += InsightCatalogue.q9Live(model: RouteCardBuilder.build(input).thereAndBack, routeId: routeId, rideId: rideId, basedOnN: stats.count, nowMs: nowMs)
        }
        let variants = insightVariants(database, routeId: routeId, stats: stats)
        // Q2-live: tight on arrival (margin), a more efficient variant
        if let battery {
            let planned = ((try? routes.variants(routeId: routeId)) ?? []).first { $0.isReference }?.id
            out += InsightCatalogue.q2Live(batteryPct: battery.pct, plannedVariantId: planned, variants: variants, routeId: routeId, rideId: rideId, nowMs: nowMs)
        }
        // Q15-live: forecast headwind along the reference path
        if let hw = forecastHeadwind(database, routeId: routeId, todayS: Geo.median(stats.compactMap(\.totalS)) ?? 900, nowMs: nowMs) {
            out += InsightCatalogue.q15Live(routeId: routeId, routeName: RouteService.title(routeId: route.id, database: database), forecastHeadwindKmh: hw,
                                            routeEffects: FactorEffects.forRoute(database, routeId: routeId), rideId: rideId, nowMs: nowMs)
        }
        return out
    }

    /// The forecast headwind along the route's reference path for leaving now (M16 on the path as fixes, forecast rows of
    /// the path's first ~1 km cell). nil: no path or no forecast.
    static func forecastHeadwind(_ database: AppDatabase, routeId: String, todayS: Double, nowMs: Int64) -> Double? {
        let variants = (try? RouteQueries(database).variants(routeId: routeId)) ?? []
        guard let v = variants.first(where: { $0.isReference }) ?? variants.first else { return nil }
        let path = Geo.decode(v.polyline ?? "")
        guard path.count >= 2, let first = path.first else { return nil }
        let step = max(1, todayS) * 1000 / Double(path.count - 1)
        let fixes = path.enumerated().map { FactorFix(t: Int64(Double($0.offset) * step), lat: $0.element.lat, lon: $0.element.lon, hAccM: 5) }
        let cell = GeoCell.key(lat: first.lat, lon: first.lon)
        let rows = (try? OutsideQueries(database).weather(cell: cell, from: OutsideTime.floorHour(nowMs) - OutsideTime.hourMs,
                                                          to: OutsideTime.floorHour(nowMs) + 3 * OutsideTime.hourMs, kind: .forecast)) ?? []
        guard !rows.isEmpty else { return nil }
        return RideWeatherCalc.headwind(fixes: fixes, rideStartMs: nowMs, rows: rows)
    }

    // MARK: Weekly

    /// The running week ("This week so far") and the last finished one ("Last week"): Q22, Q4-weekly, Q13-weekly.
    @discardableResult
    static func weekly(_ database: AppDatabase, nowMs: Int64 = nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) throws -> Report {
        guard !database.isReadOnly else { return Report() }
        let store = InsightQueries(database)
        let week = 7 * OutsideTime.dayMs
        let current = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin)
        var report = Report()
        for (start, label) in [(current - week, "Last week"), (current, "This week so far")] {
            let candidates = try weekCandidates(database, start: start, label: label, nowMs: nowMs)
            guard !candidates.isEmpty else { continue }
            let merge = InsightDedupe.merge(candidates: candidates, existing: try store.forWeek(start), nowMs: nowMs, summarySeen: false)
            try store.save(merge)
            report.made += candidates.count
            report.inserted += merge.insert.count
            report.updated += merge.update.count
        }
        return report
    }

    /// Q22 + Q4-weekly + Q13-weekly of one week (Sunday 00:00 local start), made from the stored rides
    static func weekCandidates(_ database: AppDatabase, start: Int64, label: String, nowMs: Int64) throws -> [Insight] {
        let store = InsightQueries(database)
        let week = 7 * OutsideTime.dayMs
        let rides = try store.weekRides(from: start, to: start + week)
        let before = try store.weekRides(from: start - week, to: start)
        let prevKm: Double? = before.isEmpty ? nil : before.reduce(0.0) { $0 + $1.ride.distanceM } / 1000
        var candidates = InsightCatalogue.q22Weekly(weekStart: start, rides: rides.map(\.ride), previousWeekKm: prevKm, label: label, nowMs: nowMs)
        let explanations = rides.filter { $0.ride.kind == "ride" }.compactMap { FactorEffects.forRide(database, rideId: $0.id, nowMs: nowMs) }
        candidates += InsightCatalogue.q4Weekly(weekStart: start, explanations: explanations, nowMs: nowMs)
        candidates += InsightCatalogue.q13Weekly(weekStart: start, rides: rides.map(\.ride), capKmh: nil, savedS: nil, costPct: nil, nowMs: nowMs)
        return candidates
    }

    struct PastWeek: Identifiable, Equatable {
        var start: Int64
        var title: String
        var lines: [String]
        var id: Int64 { start }
    }

    /// M4-09: the finished weeks before the last one that have a summary (2 riding days or more), newest first; made live from the
    /// rides (nothing stored, so a week the app was not opened in is still there)
    static func pastWeeks(_ database: AppDatabase, count: Int = 12, nowMs: Int64 = nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> [PastWeek] {
        let week = 7 * OutsideTime.dayMs
        let current = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        df.dateFormat = "d MMM"
        let order: [InsightType] = [.q22Weekly, .q4Weekly, .q13Weekly]
        var out: [PastWeek] = []
        for i in 2...max(2, count + 1) {
            let start = current - Int64(i) * week
            let title = "Week of " + df.string(from: Date(timeIntervalSince1970: Double(start) / 1000))
            guard let found = try? weekCandidates(database, start: start, label: title, nowMs: nowMs), !found.isEmpty else { continue }
            let lines = found.sorted { (order.firstIndex(of: $0.type) ?? 9) < (order.firstIndex(of: $1.type) ?? 9) }.map(\.text)
            out.append(PastWeek(start: start, title: title, lines: lines))
        }
        return out
    }
}

/// The "simulated windy week" (M4_PLAN section 6, check mi1): `FactorSeed.commute` (a made-up windy commute in the ocean) on a
/// saved route "Seed commute", then the factors and the insights of its last ride, as after a real ride. Always in a temporary
/// database (u32, the Developer → Insights screen, the app-tests); never on the real one.
enum InsightSeed {
    static let routeId = "seed-route"
    static let routeName = "Seed commute"

    enum SeedError: Error { case noRide }

    struct Result {
        var lastRideId: String
        var nowMs: Int64
        var report: InsightRunner.Report
    }

    /// `rides` 4 = below the gate (2 windy rides: the progress line); 24 = above it (the wind effect is known).
    @discardableResult
    static func windyWeek(_ database: AppDatabase, rides: Int) throws -> Result {
        let ids = try FactorSeed.commute(database, routeId: routeId, n: rides)
        try RouteQueries(database).save(route: RouteRecord(id: routeId, name: routeName, usualDistanceM: 5_000, state: "saved", createdAt: FactorSamples.t0))
        guard let last = ids.last, let end = try InsightQueries(database).ride(last)?.endAt else {
            throw SeedError.noRide
        }
        let now = end + OutsideTime.hourMs
        try FactorUpdater.update(database, rideId: last, nowMs: now)
        let report = try InsightRunner.afterRide(database, rideId: last, nowMs: now)
        try InsightRunner.weekly(database, nowMs: now, utcOffsetMin: FactorSeed.utcOffsetMin)
        return Result(lastRideId: last, nowMs: now, report: report)
    }
}
