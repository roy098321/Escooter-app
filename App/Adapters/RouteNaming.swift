import CoreLocation
import CorckieCore
import Foundation

/// M2-02: names variants after a street, and places that have no name after their street (CALC_SPEC M12 "Naming"). The street
/// comes from the phone's reverse geocoder (`CLGeocoder`). P-2 / P5_DILEMMAS D3: only **rounded** coordinates (3 decimals,
/// about 100 m) are looked up, at most 5 per variant, every answer is cached on the phone, nothing else is sent. With no
/// answer (offline, no street) the fallback name "Variant N" stays and the lookup is tried again the next time the route
/// card opens. A name typed by the owner (`nameByHand`) is never replaced. Read-only for the scooter: unrelated to the link.
actor RouteNaming {
    static let shared = RouteNaming()

    private let geocoder = CLGeocoder()
    private var busy = false

    /// Fire and forget: called when a ride closes (real or simulated database) and when a route card opens.
    static func start(rideId: String, database: AppDatabase?) {
        guard let database, let link = try? RouteQueries(database).link(rideId: rideId), let routeId = link.routeId else { return }
        start(routeId: routeId, database: database)
    }

    static func start(routeId: String, database: AppDatabase) {
        Task.detached(priority: .utility) { await RouteNaming.shared.run(routeId: routeId, database: database) }
    }

    func run(routeId: String, database: AppDatabase) async {
        guard !busy, !database.isReadOnly else { return }
        busy = true
        defer { busy = false }
        let store = RouteQueries(database)
        guard let variants = try? store.variants(routeId: routeId), !variants.isEmpty else { return }
        let reference = variants.first { $0.isReference } ?? variants[0]
        let referencePath = Geo.decode(reference.polyline ?? "")
        let routeLength = (try? store.route(id: routeId))?.usualDistanceM ?? 0

        var index = 0
        for v in variants {
            index += 1
            let fallback = v.name == nil || (v.name?.hasPrefix("Variant ") == true)
            guard fallback, !v.nameByHand else { continue }
            let path = Geo.decode(v.polyline ?? "")
            let part = v.id == reference.id ? path : VariantMatcher.distinguishingPoints(of: path, against: referencePath, routeLengthM: routeLength)
            var streets: [String?] = []
            var answered = 0
            for p in StreetNaming.samplePoints(part, max: 5) {
                let r = await street(at: p, database: database)
                if r.answered { answered += 1 }
                streets.append(r.street)
            }
            guard answered > 0 else { continue }                       // offline: keep the fallback, try again later
            if let street = StreetNaming.longest(streets) {
                try? store.rename(variantId: v.id, name: StreetNaming.variantName(street: street, fallbackIndex: index), byHand: false)
            }
        }

        // places with no name get the street they are on
        if let route = try? store.route(id: routeId) {
            for id in [route.fromPlaceId, route.toPlaceId] {
                guard let id, let place = try? store.place(id: id), place.name == nil else { continue }
                let r = await street(at: GeoPoint(lat: place.lat, lon: place.lon), database: database)
                if let s = r.street { try? store.rename(placeId: id, name: s) }
            }
        }
    }

    /// One street for one (rounded) point: from the cache, else from the geocoder. `answered` = the geocoder (or the cache) gave an
    /// answer, even "no street here"; false = it could not be asked (offline, throttled).
    private func street(at point: GeoPoint, database: AppDatabase) async -> (street: String?, answered: Bool) {
        let q = RideQueries(database)
        let key = StreetNaming.cacheKey(point)
        if let json = try? q.setting(key: key), let data = json.data(using: .utf8),
           let cached = try? JSONDecoder().decode(String.self, from: data) {
            return (cached.isEmpty ? nil : cached, true)
        }
        let rounded = StreetNaming.rounded(point)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: rounded.lat, longitude: rounded.lon))
            let name = marks.first?.thoroughfare
            if let data = try? JSONEncoder().encode(name ?? ""), let text = String(data: data, encoding: .utf8) {
                try? q.setSetting(key: key, json: text)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return (name, true)
        } catch {
            return (nil, false)
        }
    }
}
