import CorckieCore
import Foundation

/// M2-04: reads the route tables into the inputs of the Core builders (`RouteCardBuilder`, `RouteListBuilder`). Compiled into
/// AppTests too. The screens only draw what the builders return.
enum RouteCardLoader {
    static func stats(_ rows: [RouteRideRow]) -> [RouteRideStats] {
        rows.map { r -> RouteRideStats in
            RouteRideStats(rideId: r.id, startAt: r.startAt, utcOffsetMin: r.utcOffsetMin ?? 0, variantId: r.variantId, totalS: r.totalS,
                           distanceM: r.distanceM, avgMovingMps: r.avgMovingMps, usedPct: r.usedPct, elevGainM: r.elevGainM,
                           elevLossM: r.elevLossM, excluded: r.excludedFromUsual, windLevel: r.windLevel, wet: r.wet)
        }
    }

    static func currentMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func currentOffsetMin() -> Int { TimeZone.current.secondsFromGMT() / 60 }

    /// nil: no such route.
    static func cardInput(routeId: String, database: AppDatabase, nowMs: Int64 = currentMs(), utcOffsetMin: Int = currentOffsetMin(),
                          battery: BatteryNow? = nil) -> RouteCardInput? {
        let store = RouteQueries(database)
        guard let route = try? store.route(id: routeId) else { return nil }
        let routes = (try? store.routes()) ?? []
        let places = (try? store.places()) ?? []
        func placeName(_ id: String?) -> String? {
            guard let id else { return nil }
            return places.first { $0.id == id }?.name
        }
        var variants: [VariantInfo] = []
        for v in (try? store.variants(routeId: routeId)) ?? [] {
            variants.append(VariantInfo(id: v.id, routeId: routeId, name: v.name ?? "Variant", nameByHand: v.nameByHand,
                                        path: Geo.decode(v.polyline ?? ""), isReference: v.isReference))
        }
        let rides = stats((try? store.routeRides(routeId: routeId)) ?? [])
        var other: [RouteRideStats] = []
        if let reverse = routes.first(where: { $0.id != routeId && $0.state != "dismissed" && $0.fromPlaceId == route.toPlaceId && $0.toPlaceId == route.fromPlaceId }) {
            other = stats((try? store.routeRides(routeId: reverse.id)) ?? [])
        }
        let ordinal = (routes.firstIndex { $0.id == routeId } ?? 0) + 1
        return RouteCardInput(routeId: routeId, customName: route.name, fromName: placeName(route.fromPlaceId), toName: placeName(route.toPlaceId),
                              ordinal: ordinal, state: RouteState(rawValue: route.state) ?? .suggested, variants: variants, rides: rides,
                              otherDirection: other, nowMs: nowMs, utcOffsetMin: utcOffsetMin, battery: battery,
                              canChargeAtEnd: places.first { $0.id == route.toPlaceId }?.canCharge ?? false)
    }

    static func card(routeId: String, database: AppDatabase, battery: BatteryNow? = nil) -> RouteCardModel? {
        cardInput(routeId: routeId, database: database, battery: battery).map { RouteCardBuilder.build($0) }
    }

    /// The route that goes the other way (B to A), if there is one that is not dismissed.
    static func reverse(of route: RouteRecord, in routes: [RouteRecord]) -> RouteRecord? {
        routes.first { $0.id != route.id && $0.state != "dismissed" && $0.fromPlaceId == route.toPlaceId && $0.toPlaceId == route.fromPlaceId }
    }

    /// The Routes list. `battery` is the scooter's battery now (or last seen): with it saved routes are greyed / chipped (M2-05).
    static func list(database: AppDatabase, nowMs: Int64 = currentMs(), battery: BatteryNow? = nil,
                     utcOffsetMin: Int = currentOffsetMin()) -> RouteListModel {
        let store = RouteQueries(database)
        let routes = (try? store.routes()) ?? []
        let places = (try? store.places()) ?? []
        var inputs: [RouteListInput] = []
        for route in routes {
            let state = RouteState(rawValue: route.state) ?? .suggested
            var back: [RouteRideStats] = []
            if let r = reverse(of: route, in: routes) { back = stats((try? store.routeRides(routeId: r.id)) ?? []) }
            let charge = places.first { $0.id == route.toPlaceId }?.canCharge ?? false
            inputs.append(RouteListInput(routeId: route.id, title: RouteService.title(routeId: route.id, database: database), state: state,
                                         rides: stats((try? store.routeRides(routeId: route.id)) ?? []), nowMs: nowMs, reverseRides: back,
                                         battery: battery, canChargeAtEnd: charge, utcOffsetMin: utcOffsetMin))
        }
        return RouteListBuilder.build(inputs)
    }

    /// M2-05: the Places screen rows (a place's routes are the saved or suggested ones that start or end there).
    static func places(database: AppDatabase) -> [PlaceRowModel] {
        let store = RouteQueries(database)
        let routes = ((try? store.routes()) ?? []).filter { $0.state != "dismissed" }
        return ((try? store.places()) ?? []).map { p in
            let count = routes.filter { $0.fromPlaceId == p.id || $0.toPlaceId == p.id }.count
            return PlaceListBuilder.row(id: p.id, name: p.name, radiusM: p.radiusM, canCharge: p.canCharge, routeCount: count)
        }
    }
}
