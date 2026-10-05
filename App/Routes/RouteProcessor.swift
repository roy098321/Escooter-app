import CorckieCore
import Foundation

// M2-01 / M2-02: the glue between the database and `RouteBook` (CorckieCore, Linux tested). At every ride close the Recorder
// calls `RouteProcessor.process`: it loads the places / routes / variants, asks the book where the ride belongs, and writes the
// result back (new places, a suggested route, variants, the ride's links, the usual distance). Compiled into AppTests too.

struct RouteProcessResult: Equatable {
    var outcome: RideOutcome
    var routeId: String?
    var variantId: String?
    /// Rides on the route after this one (0 when not on a route)
    var ridesOnRoute: Int
    /// New variants created by this ride (the app names them after a street when the phone can)
    var newVariantIds: [String]
    var milliseconds: Int
}

enum RouteProcessor {
    /// How many unassigned earlier rides are looked at for a same-trip match (newest first); keeps ride close fast
    static let poolLimit = 40
    /// Rides read for the medoid of a variant
    static let medoidRides = 20

    /// nil: nothing to do (no such ride, or a discarded piece / a merged piece).
    @discardableResult
    static func process(rideId: String, database: AppDatabase) throws -> RouteProcessResult? {
        let started = Date()
        let rides = RideQueries(database)
        let store = RouteQueries(database)
        guard let ride = try rides.ride(id: rideId), ride.kind != "discarded", ride.mergeGroupId == nil else { return nil }

        var book = try loadBook(store)
        let routed = try routedRide(ride, store)
        var pool: [RoutedRide] = []
        for other in try store.unassignedRides(limit: poolLimit, excluding: rideId, simulated: ride.isSimulated) {
            pool.append(try routedRide(other, store))
        }
        let update = book.ingest(routed, pool: pool)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for p in update.newPlaces {
            try store.save(place: PlaceRecord(id: p.id, name: p.name, lat: p.point.lat, lon: p.point.lon, radiusM: p.radiusM,
                                              canCharge: p.canCharge, learnedAltM: nil, createdAt: now))
        }
        for r in update.newRoutes {
            try store.save(route: RouteRecord(id: r.id, fromPlaceId: r.fromPlaceId, toPlaceId: r.toPlaceId, name: r.name,
                                              usualDistanceM: r.usualDistanceM, sizeClass: r.sizeClass, state: r.state.rawValue, createdAt: now))
        }
        for v in update.newVariants {
            try store.save(variant: VariantRecord(id: v.id, routeId: v.routeId, name: v.name, nameByHand: v.nameByHand,
                                                  polyline: Geo.encode(v.path), isReference: v.isReference, isCombination: false))
        }
        var touched: [String] = []
        for a in update.assignments {
            guard let routeId = a.routeId else { continue }
            try store.setLink(rideId: a.rideId, RideRouteLink(routeId: routeId, variantId: a.variantId, startPlaceId: a.startPlaceId,
                                                              endPlaceId: a.endPlaceId))
            if let route = book.routes.first(where: { $0.id == routeId }), let size = route.sizeClass {
                try store.setRideKind(rideId: a.rideId, kind: size)        // M36: rides on a route take its size class
            }
            if !touched.contains(routeId) { touched.append(routeId) }
        }
        for routeId in touched {
            try refreshUsualDistance(routeId, store)
            try refreshReference(routeId, store)
        }

        let first = update.assignments.first
        let routeId = first?.routeId
        var onRoute = 0
        if let routeId { onRoute = try store.rideCount(routeId: routeId) }
        let result = RouteProcessResult(outcome: first?.outcome ?? .pending, routeId: routeId, variantId: first?.variantId,
                                        ridesOnRoute: onRoute,
                                        newVariantIds: update.newVariants.map { $0.id },
                                        milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        // check q2: how long the last ride took
        try? rides.setSetting(key: "q2.routeMs", json: "{\"ms\":\(result.milliseconds),\"pool\":\(pool.count)}")
        return result
    }

    // MARK: Loading

    static func loadBook(_ store: RouteQueries) throws -> RouteBook {
        var book = RouteBook()
        for p in try store.places() {
            book.places.append(PlaceInfo(id: p.id, name: p.name, point: GeoPoint(lat: p.lat, lon: p.lon), radiusM: p.radiusM, canCharge: p.canCharge))
        }
        for r in try store.routes() {
            guard let from = r.fromPlaceId, let to = r.toPlaceId else { continue }
            book.routes.append(RouteInfo(id: r.id, fromPlaceId: from, toPlaceId: to, name: r.name, usualDistanceM: r.usualDistanceM ?? 0,
                                         state: RouteState(rawValue: r.state) ?? .suggested, sizeClass: r.sizeClass))
        }
        for v in try store.variants() {
            guard let routeId = v.routeId else { continue }
            book.variants.append(VariantInfo(id: v.id, routeId: routeId, name: v.name ?? "Variant", nameByHand: v.nameByHand,
                                             path: Geo.decode(v.polyline ?? ""), isReference: v.isReference))
        }
        return book
    }

    static func routedRide(_ ride: RideRecord, _ store: RouteQueries) throws -> RoutedRide {
        let samples = try store.pathSamples(rideId: ride.id).map {
            RoutePathSample(lat: $0.lat, lon: $0.lon, hAccM: $0.hAccM, odometerKm: $0.odometerKm)
        }
        return RoutedRide(id: ride.id, startAt: ride.startAt, distanceM: ride.distanceM ?? 0, shape: TripBuilder.shape(samples))
    }

    // MARK: Keeping the route tidy

    /// The route's usual distance = the median of its rides' distances.
    static func refreshUsualDistance(_ routeId: String, _ store: RouteQueries) throws {
        let distances = try store.routeRides(routeId: routeId).compactMap { $0.distanceM }.filter { $0 > 0 }
        if let m = Geo.median(distances) { try store.setUsualDistance(routeId: routeId, distanceM: m) }
    }

    /// M12 Reference: the first ride's path is the reference; once the most common variant has 3 rides (and then every 5th)
    /// the reference becomes the medoid of that variant's newest rides.
    static func refreshReference(_ routeId: String, _ store: RouteQueries) throws {
        let rows = try store.routeRides(routeId: routeId)
        var counts: [String: Int] = [:]
        for r in rows { if let v = r.variantId { counts[v, default: 0] += 1 } }
        let variants = try store.variants(routeId: routeId)
        guard !variants.isEmpty else { return }
        let current = variants.first { $0.isReference }
        var best = current
        for v in variants {
            let n = counts[v.id, default: 0]
            if n > counts[best?.id ?? "", default: 0] { best = v }
        }
        guard let target = best, let n = counts[target.id], n >= 3, n == 3 || n % 5 == 0 else { return }
        var paths: [[GeoPoint]] = []
        for r in rows where r.variantId == target.id {
            guard let ride = try RideQueries(store.database).ride(id: r.id) else { continue }
            let shape = try routedRide(ride, store).shape
            if shape.path.count >= 2, !shape.hasGap { paths.append(shape.path) }
            if paths.count >= medoidRides { break }
        }
        guard paths.count >= 3, let index = VariantMatcher.medoidIndex(of: paths) else { return }
        for v in variants {
            var changed = v
            if v.id == target.id {
                changed.polyline = Geo.encode(paths[index])
                changed.isReference = true
            } else {
                changed.isReference = false
            }
            if changed != v { try store.save(variant: changed) }
        }
    }
}

/// Actions the screens use on routes: save a suggestion, say "Not a route", rename, remove.
enum RouteService {
    /// "Save as route?" → Save
    static func save(routeId: String, database: AppDatabase) throws {
        try RouteQueries(database).setState(routeId: routeId, state: "saved")
    }

    /// "Not a route": the route row stays as `dismissed` so the trip is never suggested again; its rides lose the link.
    static func dismiss(routeId: String, database: AppDatabase) throws {
        let store = RouteQueries(database)
        try store.setState(routeId: routeId, state: "dismissed")
        try store.detachRides(routeId: routeId)
    }

    /// Remove a saved route: it is dismissed too, so the same two trips do not make a new suggestion at once.
    static func remove(routeId: String, database: AppDatabase) throws {
        try dismiss(routeId: routeId, database: database)
    }

    static func rename(routeId: String, name: String?, database: AppDatabase) throws {
        try RouteQueries(database).rename(routeId: routeId, name: name)
    }

    /// The text of a route: its own name, "Home → Work" from the places, or "Route 3".
    static func title(routeId: String, database: AppDatabase) -> String {
        let store = RouteQueries(database)
        guard let route = try? store.route(id: routeId) else { return "Route" }
        let from = route.fromPlaceId.flatMap { try? store.place(id: $0) }?.name
        let to = route.toPlaceId.flatMap { try? store.place(id: $0) }?.name
        return RouteLabels.title(customName: route.name, fromName: from, toName: to, ordinal: (try? store.ordinal(ofRoute: routeId)) ?? 1)
    }

    /// What the ride summary shows about the ride's route (nil: not on a route, or the route was dismissed).
    static func offer(rideId: String, database: AppDatabase) -> RouteOfferModel? {
        let store = RouteQueries(database)
        guard let link = try? store.link(rideId: rideId), let routeId = link.routeId,
              let route = try? store.route(id: routeId), let state = RouteState(rawValue: route.state) else { return nil }
        let count = (try? store.rideCount(routeId: routeId)) ?? 0
        return RouteOfferModel.make(routeId: routeId, state: state, title: title(routeId: routeId, database: database), ridesOnRoute: count)
    }
}

/// M2-05: what the Places screen changes.
enum PlaceService {
    static func rename(placeId: String, name: String?, database: AppDatabase) throws {
        try RouteQueries(database).rename(placeId: placeId, name: name)
    }

    static func setRadius(placeId: String, radiusM: Double?, database: AppDatabase) throws {
        try RouteQueries(database).setRadius(placeId: placeId, radiusM: radiusM)
    }

    static func setCanCharge(placeId: String, canCharge: Bool, database: AppDatabase) throws {
        try RouteQueries(database).setCanCharge(placeId: placeId, canCharge: canCharge)
    }
}
