import CorckieCore
import Foundation
import Observation

/// M2-06: "Where to?" on Home picks the route the next ride follows. The choice lives in memory only and is cleared when the ride
/// that used it is over. (Guessing the destination by itself is Q1, M4.)
@Observable
final class RouteFollowSelection {
    static let shared = RouteFollowSelection()
    var routeId: String?
    private init() {}

    func toggle(_ id: String) { routeId = routeId == id ? nil : id }
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
        return WhereTo.chips(inputs, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
    }

    /// The followed path is the reference variant (else the first one); Today is for leaving now. Without 3 rides the median of what
    /// exists, else the length at 5.5 m/s.
    static func follower(routeId: String, database: AppDatabase, nowMs: Int64 = RouteCardLoader.currentMs(),
                         utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> RouteFollower? {
        let store = RouteQueries(database)
        guard let route = try? store.route(id: routeId) else { return nil }
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
    /// M2-09 (Q9): the one line shown at ride start when the way back will not fit, from `neededPct` (with the margin) of both legs.
    /// nil = it fits, or not enough data, or no battery reading.
    static func returnWarning(routeId: String, database: AppDatabase, battery: BatteryNow) -> String? {
        guard let input = RouteCardLoader.cardInput(routeId: routeId, database: database, battery: battery),
              let m = RouteCardBuilder.build(input).thereAndBack else { return nil }
        return ThereAndBack.startWarning(m)
    }
}
