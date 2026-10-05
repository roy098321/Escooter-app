import Foundation

public enum RouteState: String, Codable, Sendable {
    case suggested, saved, dismissed
}

/// M2-01: a directional route A → B (DATA_MODEL `route`).
public struct RouteInfo: Codable, Equatable, Sendable {
    public var id: String
    public var fromPlaceId: String
    public var toPlaceId: String
    public var name: String?
    public var usualDistanceM: Double
    public var state: RouteState
    /// M36: "ride" or "shortHop"; rides on the route take it
    public var sizeClass: String?

    public init(id: String, fromPlaceId: String, toPlaceId: String, name: String? = nil, usualDistanceM: Double,
                state: RouteState = .suggested, sizeClass: String? = nil) {
        self.id = id
        self.fromPlaceId = fromPlaceId
        self.toPlaceId = toPlaceId
        self.name = name
        self.usualDistanceM = usualDistanceM
        self.state = state
        self.sizeClass = sizeClass
    }
}

/// One finished ride as the route logic sees it.
public struct RoutedRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var distanceM: Double
    public var shape: TripShape

    public init(id: String, startAt: Int64, distanceM: Double, shape: TripShape) {
        self.id = id
        self.startAt = startAt
        self.distanceM = distanceM
        self.shape = shape
    }
}

public enum RideOutcome: Equatable, Sendable {
    /// On a saved route
    case matched
    /// On a suggested route (the "Save as route?" card); the app counts the rides on it
    case suggested
    /// First trip between two spots: waiting for a second one (T63)
    case pending
    /// Start and end are the same place (M11 S2)
    case loop
    /// No good GPS at the start or the end: not matched (STATES S2)
    case noGps
    /// Under 0.5 km (M36)
    case tooShort
    /// Matches a route the owner said "Not a route" to
    case dismissedRoute
}

public struct RideAssignment: Equatable, Sendable {
    public var rideId: String
    public var outcome: RideOutcome
    public var routeId: String?
    public var variantId: String?
    public var startPlaceId: String?
    public var endPlaceId: String?
}

/// What `RouteBook.ingest` changed, for the app to write to the database.
public struct RouteUpdate: Equatable, Sendable {
    public var assignments: [RideAssignment] = []
    public var newPlaces: [PlaceInfo] = []
    public var newRoutes: [RouteInfo] = []
    public var newVariants: [VariantInfo] = []
    /// The first assignment is the ride that was ingested; the others are earlier rides that joined a new route.
    public var rideAssignment: RideAssignment? { assignments.first }
}

/// M11 / M12 in one value: the places, routes and variants known so far. `ingest` takes a finished ride and says
/// where it belongs. Pure: the app loads a book from the database, ingests, and writes the `RouteUpdate` back.
public struct RouteBook: Equatable, Sendable {
    public var places: [PlaceInfo]
    public var routes: [RouteInfo]
    public var variants: [VariantInfo]

    public init(places: [PlaceInfo] = [], routes: [RouteInfo] = [], variants: [VariantInfo] = []) {
        self.places = places
        self.routes = routes
        self.variants = variants
    }

    /// Trips under 0.5 km are never routes (M36 discarded pieces)
    public static let minTripM = RideSizeClass.discardBelowM

    // MARK: Ingest

    /// `pool` = earlier rides that are not on any route yet (newest first is fine, the order does not matter).
    public mutating func ingest(_ ride: RoutedRide, pool: [RoutedRide], makeID: () -> String = { UUID().uuidString }) -> RouteUpdate {
        var update = RouteUpdate()
        func plain(_ outcome: RideOutcome) -> RouteUpdate { Self.plainUpdate(ride.id, outcome) }
        guard let s = ride.shape.start, let e = ride.shape.end else { return plain(.noGps) }
        guard ride.distanceM >= Self.minTripM else { return plain(.tooShort) }

        // 1. a route that already exists
        if let route = matchRoute(start: s, end: e, distanceM: ride.distanceM) {
            if route.state == .dismissed { return plain(.dismissedRoute) }
            let assignment = assign(ride, to: route, makeID: makeID, update: &update)
            update.assignments = [assignment]
            return update
        }

        // 2. a loop is not a route
        let tol = PlaceMatcher.toleranceM(tripLengthM: ride.distanceM)
        if Geo.distanceM(s, e) <= tol { return plain(.loop) }

        // 3. earlier rides that made the same trip (T63: two trips make a suggestion)
        var mates: [RoutedRide] = []
        for other in pool where other.id != ride.id {
            guard let os = other.shape.start, let oe = other.shape.end, other.distanceM >= Self.minTripM else { continue }
            let t = PlaceMatcher.toleranceM(tripLengthM: max(ride.distanceM, other.distanceM))
            if Geo.distanceM(s, os) <= t, Geo.distanceM(e, oe) <= t, Geo.distanceM(os, oe) > t { mates.append(other) }
        }
        guard mates.count + 1 >= T.t63SuggestRouteTrips else { return plain(.pending) }

        // New suggested route: places at the FIRST trip's points (not averaged: they would drift)
        let all = (mates + [ride]).sorted { $0.startAt < $1.startAt }
        guard let firstTrip = all.first, let fs = firstTrip.shape.start, let fe = firstTrip.shape.end else { return plain(.pending) }
        var sp = PlaceMatcher.nearest(to: fs, in: places, tripLengthM: firstTrip.distanceM)
        if sp == nil { sp = newPlace(at: fs, makeID: makeID, update: &update) }
        var ep = PlaceMatcher.nearest(to: fe, in: places, tripLengthM: firstTrip.distanceM)
        if ep == nil { ep = newPlace(at: fe, makeID: makeID, update: &update) }
        guard let startPlace = sp, let endPlace = ep else { return plain(.pending) }
        let usual = Geo.median(all.map { $0.distanceM }) ?? ride.distanceM
        let route = RouteInfo(id: makeID(), fromPlaceId: startPlace.id, toPlaceId: endPlace.id, name: nil, usualDistanceM: usual,
                              state: .suggested, sizeClass: RideSizeClass.of(distanceM: usual).rawValue)
        routes.append(route)
        update.newRoutes.append(route)
        var assignments: [RideAssignment] = []
        for r in all { assignments.append(assign(r, to: route, makeID: makeID, update: &update)) }
        // the ingested ride first
        if let i = assignments.firstIndex(where: { $0.rideId == ride.id }) { assignments.swapAt(0, i) }
        update.assignments = assignments
        return update
    }

    // MARK: Pieces

    static func plainUpdate(_ rideId: String, _ outcome: RideOutcome) -> RouteUpdate {
        var u = RouteUpdate()
        u.assignments = [RideAssignment(rideId: rideId, outcome: outcome, routeId: nil, variantId: nil, startPlaceId: nil, endPlaceId: nil)]
        return u
    }

    /// The route whose two places both reach the trip's ends (nearest places win). Dismissed routes count, so they stay dismissed.
    func matchRoute(start: GeoPoint, end: GeoPoint, distanceM: Double) -> RouteInfo? {
        var best: (route: RouteInfo, d: Double)?
        for route in routes {
            guard let from = places.first(where: { $0.id == route.fromPlaceId }),
                  let to = places.first(where: { $0.id == route.toPlaceId }) else { continue }
            let length = route.usualDistanceM > 0 ? route.usualDistanceM : distanceM       // M11: saved routes use their usual distance (S4)
            let dS = Geo.distanceM(start, from.point)
            let dE = Geo.distanceM(end, to.point)
            if dS <= PlaceMatcher.radiusM(of: from, tripLengthM: length), dE <= PlaceMatcher.radiusM(of: to, tripLengthM: length) {
                let d = dS + dE
                if best == nil || d < best!.d { best = (route, d) }
            }
        }
        return best?.route
    }

    private mutating func newPlace(at p: GeoPoint, makeID: () -> String, update: inout RouteUpdate) -> PlaceInfo {
        let place = PlaceInfo(id: makeID(), name: nil, point: p)
        places.append(place)
        update.newPlaces.append(place)
        return place
    }

    /// Puts a ride on a route and on one of its variants (the first ride creates the reference variant).
    private mutating func assign(_ ride: RoutedRide, to route: RouteInfo, makeID: () -> String, update: inout RouteUpdate) -> RideAssignment {
        let own = variants.filter { $0.routeId == route.id }
        var variantId: String?
        if own.isEmpty {
            let v = VariantInfo(id: makeID(), routeId: route.id, name: "Variant 1", path: ride.shape.path, isReference: true)
            variants.append(v)
            update.newVariants.append(v)
            variantId = v.id
        } else {
            let length = route.usualDistanceM > 0 ? route.usualDistanceM : ride.distanceM
            switch VariantMatcher.classify(ride.shape.path, variants: own, routeLengthM: length) {
            case .same(let id):
                variantId = id
            case .new:
                if ride.shape.hasGap, let best = bestCoverage(ride.shape.path, own, lengthM: length) {
                    variantId = best           // GPS was lost for a while: the path between the fixes is a guess, no new variant
                } else {
                    let v = VariantInfo(id: makeID(), routeId: route.id, name: "Variant \(own.count + 1)", path: ride.shape.path)
                    variants.append(v)
                    update.newVariants.append(v)
                    variantId = v.id
                }
            }
        }
        let outcome: RideOutcome
        if route.state == .saved {
            outcome = .matched
        } else {
            outcome = .suggested
        }
        return RideAssignment(rideId: ride.id, outcome: outcome, routeId: route.id, variantId: variantId,
                              startPlaceId: route.fromPlaceId, endPlaceId: route.toPlaceId)
    }

    // MARK: Names shown to the owner

    /// Display name of a place: its own name, else "Unnamed place".
    public func placeName(_ id: String) -> String {
        places.first { $0.id == id }?.name ?? "Unnamed place"
    }
}

extension RouteBook {
    /// The variant the path covers best (used for a ride whose GPS had a gap)
    func bestCoverage(_ path: [GeoPoint], _ candidates: [VariantInfo], lengthM: Double) -> String? {
        var best: (id: String, c: Double)?
        for v in candidates {
            let c = VariantMatcher.coverage(path, on: v.path, routeLengthM: lengthM)
            if best == nil || c > best!.c { best = (v.id, c) }
        }
        return best?.id
    }
}
