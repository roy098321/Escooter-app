import CorckieCore
import Foundation

/// M6-01 (Q23): choice points after every ride, the fastest combination for the route card and Follow. Compiled into AppTests too.
/// - `update(db, rideId:)` from the Recorder close (after routes and factors, before the insights, so Q3 sees this ride's option):
///   the ride's route gets its choice points rebuilt from its newest rides (`ChoicePointDetector`), options named after the
///   variant whose path they follow ("via Ibn Gabirol"), else "way 2 at km 1.4".
/// - `answer(db, routeId:)`: `FastestCombination.answer` with the route's time effects (M24, only those past their gate) and
///   today's levels (rush hour and day type now, forecast headwind along the route).
enum FastestService {
    /// Newest rides a rebuild reads (keeps ride close quick; the option gate needs only 3 each)
    static let ridesPerRoute = 40

    struct Report: Equatable {
        var points = 0
        var options = 0
        var rideOptions = 0
        var milliseconds = 0
        var text: String { "Choice points: \(points), options: \(options), ride options: \(rideOptions) (\(milliseconds) ms)" }
    }

    @discardableResult
    static func update(_ database: AppDatabase, rideId: String) throws -> Report? {
        guard !database.isReadOnly, let routeId = try RouteQueries(database).link(rideId: rideId)?.routeId else { return nil }
        return try rebuild(database, routeId: routeId)
    }

    @discardableResult
    static func rebuild(_ database: AppDatabase, routeId: String) throws -> Report {
        let started = Date()
        let store = RouteQueries(database)
        let variants = try store.variants(routeId: routeId)
        guard let ref = variants.first(where: { $0.isReference }) ?? variants.first, let line = ref.polyline else {
            try ChoiceQueries(database).replace(routeId: routeId, with: .empty)
            return Report()
        }
        let reference = Geo.decode(line)
        let length = try store.route(id: routeId)?.usualDistanceM ?? Geo.pathLengthM(reference)
        let rides = try ChoiceQueries(database).rides(routeId: routeId, limit: ridesPerRoute)
        var set = ChoicePointDetector.detect(routeId: routeId, reference: reference, rides: rides, routeLengthM: length)
        // names: the variant (not the reference) whose path the option follows
        let others = variants.filter { $0.id != ref.id }.compactMap { v -> (String, [GeoPoint])? in
            guard let name = v.name, let p = v.polyline else { return nil }
            return (name, Geo.decode(p))
        }
        for i in set.points.indices {
            for j in set.points[i].options.indices where !set.points[i].options[j].isReference {
                let path = set.points[i].options[j].path
                if let hit = others.first(where: { ChoicePointDetector.shareWithin(path, of: $0.1, m: ChoicePointDetector.sameOptionM) >= ChoicePointDetector.sameOptionShare }),
                   !hit.0.hasPrefix("Variant ") {
                    set.points[i].options[j].name = hit.0
                }
            }
        }
        try ChoiceQueries(database).replace(routeId: routeId, with: set)
        var report = Report()
        report.points = set.points.count
        report.options = set.points.reduce(0) { $0 + $1.options.count }
        report.rideOptions = set.costs.count
        report.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        try? RideQueries(database).setSetting(key: "q23.routeMs", json: "{\"ms\":\(report.milliseconds),\"rides\":\(rides.count)}")
        return report
    }

    // MARK: The answer

    static func levels(_ r: FactorInputRow) -> Set<String> {
        var out: Set<String> = []
        if let h = r.headwindKmh {
            if h >= FactorRules.headwindLevelKmh { out.insert("head") }
            if h <= -FactorRules.headwindLevelKmh { out.insert("tail") }
        }
        if r.rushHour == true { out.insert("rush") }
        if r.dayType == "friday" || r.dayType == "saturday" { out.insert(r.dayType!) }
        return out
    }

    /// Route time effects per trip that passed their gate, by level (combined factors are left out).
    static func tripEffects(_ database: AppDatabase, routeId: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for e in FactorEffects.forRoute(database, routeId: routeId) where !e.level.contains("+") {
            if let t = e.timeEffectS { out[e.level] = t }
        }
        return out
    }

    static func todayLevels(_ database: AppDatabase, routeId: String, nowMs: Int64, utcOffsetMin: Int, todayS: Double) -> Set<String> {
        var out: Set<String> = []
        let weekday = DayClock.weekday(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        if DayClock.isRushHour(startAtMs: nowMs, utcOffsetMin: utcOffsetMin) { out.insert("rush") }
        let day = DayClock.dayType(weekday: weekday)
        if day != "workday" { out.insert(day) }
        if let h = InsightRunner.forecastHeadwind(database, routeId: routeId, todayS: todayS, nowMs: nowMs) {
            if h >= FactorRules.headwindLevelKmh { out.insert("head") }
            if h <= -FactorRules.headwindLevelKmh { out.insert("tail") }
        }
        return out
    }

    static func answer(_ database: AppDatabase, routeId: String, nowMs: Int64 = RouteCardLoader.currentMs(),
                       utcOffsetMin: Int = RouteCardLoader.currentOffsetMin(), todayLevels fixedToday: Set<String>? = nil) -> FastestAnswer? {
        let store = RouteQueries(database)
        let variants = (try? store.variants(routeId: routeId)) ?? []
        guard let ref = variants.first(where: { $0.isReference }) ?? variants.first, let line = ref.polyline else { return nil }
        let reference = Geo.decode(line)
        guard let set = try? ChoiceQueries(database).set(routeId: routeId, reference: reference) else { return nil }
        let length = (try? store.route(id: routeId))?.usualDistanceM ?? Geo.pathLengthM(reference)
        let rows = ((try? FactorQueries(database).inputs()) ?? []).filter { $0.routeId == routeId }
        let rides = rows.map { CombinationRide(id: $0.id, startAt: $0.startAt, totalS: $0.totalS, excluded: $0.excludedFromUsual, levels: levels($0)) }
        let todayS = Geo.median(rows.compactMap(\.totalS)) ?? 600
        let today = fixedToday ?? todayLevels(database, routeId: routeId, nowMs: nowMs, utcOffsetMin: utcOffsetMin, todayS: todayS)
        return FastestCombination.answer(CombinationInput(routeId: routeId, reference: reference, routeLengthM: length, choices: set,
                                                          rides: rides, tripEffectsS: tripEffects(database, routeId: routeId),
                                                          todayLevels: today, nowMs: nowMs))
    }


    static func card(_ database: AppDatabase, routeId: String, nowMs: Int64 = RouteCardLoader.currentMs()) -> FastestCard? {
        answer(database, routeId: routeId, nowMs: nowMs).flatMap(FastestCard.make)
    }
}
