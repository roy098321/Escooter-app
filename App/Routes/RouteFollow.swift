import CorckieCore
import Foundation
import GRDB
import Observation

/// M2-06: "Where to?" on Home picks the route the next ride follows. The choice lives in memory only and is cleared when the ride
/// that used it is over. (Guessing the destination by itself is Q1, M4.)
@Observable
final class RouteFollowSelection {
    static let shared = RouteFollowSelection()
    var routeId: String?
    /// M6-01 (Q23): follow the fastest combination of this route instead of its usual path (cleared with the route)
    var combination = false
    /// B31: a saved place chosen as the destination while no saved route ends there (before the ride only: the time and the battery need)
    var placeId: String?
    private init() {}

    /// The id the Where to? list and the quick dial use: the route id, else "place:<id>"
    var chosenKey: String? { routeId ?? placeId.map { QuickDialLoader.placePrefix + $0 } }

    /// Chooses by key; nil or the key already chosen clears (tap again = no destination)
    func choose(key: String?) {
        if let key, key != chosenKey {
            combination = false
            if let place = QuickDialLoader.placeId(fromKey: key) {
                routeId = nil
                placeId = place
            } else {
                placeId = nil
                routeId = key
            }
        } else {
            routeId = nil
            placeId = nil
            combination = false
        }
    }

    func toggle(_ id: String) {
        routeId = routeId == id ? nil : id
        combination = false
    }

    /// Route card → "Follow this next ride": the next ride follows the combination (tap again to stop)
    func followCombination(_ id: String) {
        if routeId == id && combination {
            routeId = nil
            combination = false
        } else {
            routeId = id
            combination = true
        }
    }
}

/// Reads the route tables into the Core builders of M2-06 (`WhereTo`, `RouteFollower`). Compiled into AppTests too.
enum RouteFollowLoader {
    /// B71 (hotfix 04): where a left-out past ride is reported (the app sets it to the log at launch; this file is in AppTests too)
    static var leftOutLog: ((String) -> Void)?

    /// - log: F-35: false when read during a ride (the live screen's picker), so the prediction log only gets what Home showed
    static func chips(database: AppDatabase, nowMs: Int64 = RouteCardLoader.currentMs(),
                      utcOffsetMin: Int = RouteCardLoader.currentOffsetMin(), log: Bool = true) -> [WhereToChip] {
        let store = RouteQueries(database)
        var inputs: [WhereToInput] = []
        for route in (try? store.routes()) ?? [] where route.state == "saved" {
            let to = route.toPlaceId.flatMap { try? store.place(id: $0) }?.name
            inputs.append(WhereToInput(routeId: route.id, title: RouteService.title(routeId: route.id, database: database), toName: to,
                                       rides: RouteCardLoader.stats((try? store.routeRides(routeId: route.id)) ?? [])))
        }
        // T-00 part 2: the "today ~N min · uses about N%" shown on each chip is written down for the prediction log
        for i in inputs where log && !i.rides.isEmpty {
            FieldKitService.logToday(database, routeId: i.routeId, rides: i.rides, nowMs: nowMs, utcOffsetMin: utcOffsetMin,
                                     departureMinute: DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin))
        }
        return WhereTo.chips(inputs, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
    }

    /// The followed path is the reference variant (else the first one); Today is for leaving now. Without 3 rides the median of what
    /// exists, else the length at 5.5 m/s.
    static func follower(routeId: String, database: AppDatabase, nowMs: Int64 = RouteCardLoader.currentMs(),
                         utcOffsetMin: Int = RouteCardLoader.currentOffsetMin(), combination: Bool = false) -> RouteFollower? {
        let store = RouteQueries(database)
        guard let route = try? store.route(id: routeId) else { return nil }
        // M6-01 (Q23): the fastest combination (ridden stretches only) with its own estimate; none any more = the usual path
        if combination, let c = FastestService.answer(database, routeId: routeId, nowMs: nowMs, utcOffsetMin: utcOffsetMin)?.combo,
           c.path.count >= 2 {
            let to = route.toPlaceId.flatMap { try? store.place(id: $0) }?.name
            let name = WhereTo.label(toName: to, title: RouteService.title(routeId: routeId, database: database))
            return RouteFollower(destinationName: name, path: c.path, todayS: c.timeS)
        }
        let variants = (try? store.variants(routeId: routeId)) ?? []
        guard let v = variants.first(where: { $0.isReference }) ?? variants.first, let line = v.polyline else { return nil }
        let path = Geo.decode(line)
        let rides = RouteCardLoader.stats((try? store.routeRides(routeId: routeId)) ?? [])
        let departure = DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        var todayS: Double?
        if case .estimate(let e) = TodayEstimator.estimate(rides: rides, nowMs: nowMs, utcOffsetMin: utcOffsetMin, departureMinute: departure) {
            todayS = e.timeS
        }
        todayS = todayS ?? Geo.median(rides.compactMap { $0.totalS })
        todayS = todayS ?? Geo.pathLengthM(path) / 5.5
        let to = route.toPlaceId.flatMap { try? store.place(id: $0) }?.name
        let name = WhereTo.label(toName: to, title: RouteService.title(routeId: routeId, database: database))
        return RouteFollower(destinationName: name, path: path, todayS: todayS ?? 600)
    }
}

extension RouteFollowLoader {
    /// F-22: the route's usual battery use per km (median of its rides), nil without data
    static func usualPctPerKm(routeId: String, database: AppDatabase) -> Double? {
        DestinationRules.usualPctPerKm(rides: RouteCardLoader.stats((try? RouteQueries(database).routeRides(routeId: routeId)) ?? []))
    }

    /// V09 timing: where riders usually stop on this route (stops of ≥ 20 s on its 3 newest rides)
    static func usualStops(routeId: String, database: AppDatabase) -> [GeoPoint] {
        let rides = ((try? RouteQueries(database).routeRides(routeId: routeId)) ?? []).filter { $0.kind == "ride" }.sorted { $0.startAt > $1.startAt }
        var out: [GeoPoint] = []
        for r in rides.prefix(3) {
            let rows = (try? database.writer.read { d in
                try Row.fetchAll(d, sql: "SELECT t, lat, lon, hAccM, speedMps, gpsSpeedMps FROM ride_sample WHERE rideId = ? ORDER BY t", arguments: [r.id])
            }) ?? []
            let pts = rows.map { row -> SeriesPoint in
                let t: Int64 = row["t"] ?? 0
                let scooter: Double? = row["speedMps"]
                let gps: Double? = row["gpsSpeedMps"]
                let lat: Double? = row["lat"], lon: Double? = row["lon"], acc: Double? = row["hAccM"]
                return SeriesPoint(t: Double(t) / 1000, lat: lat, lon: lon, hAccM: acc, speedKmh: (scooter ?? gps).map { $0 * 3.6 })
            }
            out += LayerViews.stops(pts).map(\.point)
        }
        return out
    }

    /// Hotfix 03: the route's past rides point by point (its 8 newest rides that rode it from start to end): the arrival time on the
    /// ride screen and the voice's battery and late lines. Where on the route, never when in the day. nil = none usable.
    static func history(routeId: String, follower: RouteFollower, database: AppDatabase, excludingRideId: String? = nil,
                        limit: Int = 8) -> RouteHistory? {
        let rides = ((try? RouteQueries(database).routeRides(routeId: routeId)) ?? [])
            .filter { $0.kind == "ride" && !$0.excludedFromUsual && $0.id != excludingRideId }.sorted { $0.startAt > $1.startAt }
        let wh = CalibrationUpdater.current(database).whPerPct
        var out: [RouteRideProfile] = []
        for r in rides.prefix(limit) {
            // B71 (hotfix 04): a ride whose profile uses ~0 % while its battery fell is left out, with the reason in the log
            let c = RouteRideProfile.makeChecked(samples: historySamples(rideId: r.id, database: database), route: follower, whPerPct: wh)
            if let p = c.profile { out.append(p) }
            if let why = c.leftOut { leftOutLog?("route history: ride \(r.id.prefix(8)) \(why)") }
        }
        return out.isEmpty ? nil : RouteHistory(rides: out, routeKm: follower.totalM / 1000)
    }

    /// One stored ride's readings for the history and the voice replay
    static func historySamples(rideId: String, database: AppDatabase) -> [RouteHistorySample] {
        let rows = (try? database.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT t, lat, lon, speedMps, gpsSpeedMps, batteryPct, voltage, currentA, powerW, tempC FROM ride_sample WHERE rideId = ? ORDER BY t
                """, arguments: [rideId])
        }) ?? []
        return rows.map { row -> RouteHistorySample in
            let t: Int64 = row["t"] ?? 0
            let scooter: Double? = row["speedMps"]
            let gps: Double? = row["gpsSpeedMps"]
            let volts: Double? = row["voltage"]
            let amps: Double? = row["currentA"]
            let stored: Double? = row["powerW"]
            let pct: Int? = row["batteryPct"]
            let lat: Double? = row["lat"]
            let lon: Double? = row["lon"]
            let temp: Double? = row["tempC"]
            var power = stored
            if power == nil, let v = volts, let a = amps { power = v * a }
            return RouteHistorySample(t: Double(t) / 1000, lat: lat, lon: lon, speedKmh: (scooter ?? gps).map { $0 * 3.6 },
                                      batteryPct: pct.map { Double($0) }, powerW: power, currentA: amps, tempC: temp)
        }
    }
}
