import CorckieCore
import Foundation
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
    static func chips(database: AppDatabase, nowMs: Int64 = RouteCardLoader.currentMs(),
                      utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> [WhereToChip] {
        let store = RouteQueries(database)
        var inputs: [WhereToInput] = []
        for route in (try? store.routes()) ?? [] where route.state == "saved" {
            let to = route.toPlaceId.flatMap { try? store.place(id: $0) }?.name
            inputs.append(WhereToInput(routeId: route.id, title: RouteService.title(routeId: route.id, database: database), toName: to,
                                       rides: RouteCardLoader.stats((try? store.routeRides(routeId: route.id)) ?? [])))
        }
        // T-00 part 2: the "today ~N min · uses about N%" shown on each chip is written down for the prediction log
        for i in inputs where !i.rides.isEmpty {
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

    /// M2-09 (Q9): the one line shown at ride start when the way back will not fit, from `neededPct` (with the margin) of both legs.
    /// nil = it fits, or not enough data, or no battery reading.
    static func returnWarning(routeId: String, database: AppDatabase, battery: BatteryNow) -> String? {
        guard let input = RouteCardLoader.cardInput(routeId: routeId, database: database, battery: battery),
              let m = RouteCardBuilder.build(input).thereAndBack else { return nil }
        return ThereAndBack.startWarning(m)
    }
}
