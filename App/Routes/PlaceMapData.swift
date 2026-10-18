import CorckieCore
import CoreLocation
import Foundation
import SwiftUI

/// F-08: the colour of every place. Stored per place as the setting `place.colour.<id>` (a JSON string with the colour id, no schema
/// change). A place without one gets the next colour of the set (`PlaceColours.assign`) the first time anything asks, and it is
/// written down so it stays.
enum PlaceColourStore {
    /// placeId to colour id for every place; places that have none get one now (written unless the database is read-only)
    static func colours(database: AppDatabase) -> [String: String] {
        let store = RouteQueries(database)
        let places = (try? store.places()) ?? []
        var map = (try? store.placeColours()) ?? [:]
        let fresh = PlaceColours.assign(places: places.map { (id: $0.id, name: $0.name) }, existing: map)
        guard !fresh.isEmpty else { return map }
        for (id, colour) in fresh {
            map[id] = colour
            if !database.isReadOnly { try? write(placeId: id, colourId: colour, database: database) }
        }
        return map
    }

    static func write(placeId: String, colourId: String, database: AppDatabase) throws {
        guard PlaceColours.isValid(colourId), let data = try? JSONEncoder().encode(colourId), let json = String(data: data, encoding: .utf8) else { return }
        try RideQueries(database).setSetting(key: PlaceColours.settingKey(placeId), json: json)
    }

    static func color(_ id: String?) -> Color { Color(hex: PlaceColours.hex(id)) }
}

/// A place with what the map screens need.
struct PlaceMapItem: Equatable {
    var id: String
    var row: PlaceRowModel
    var lat: Double
    var lon: Double
    var colourId: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// the circle drawn for a place with an automatic size: the tolerance of a typical 4 km trip
    static let automaticCircleM = 200.0
    var circleM: Double { row.radiusM ?? Self.automaticCircleM }
}

/// A named pin on a ride or route map (start / end place).
struct PlacePin: Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var colourId: String
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum PlaceMapLoader {
    static func items(database: AppDatabase) -> [PlaceMapItem] {
        let store = RouteQueries(database)
        let colours = PlaceColourStore.colours(database: database)
        let routes = ((try? store.routes()) ?? []).filter { $0.state != "dismissed" }
        return ((try? store.places()) ?? []).map { p in
            let count = routes.filter { $0.fromPlaceId == p.id || $0.toPlaceId == p.id }.count
            let colour = colours[p.id] ?? "orange"
            return PlaceMapItem(id: p.id, row: PlaceListBuilder.row(id: p.id, name: p.name, radiusM: p.radiusM, canCharge: p.canCharge,
                                                                    routeCount: count, colourId: colour),
                                lat: p.lat, lon: p.lon, colourId: colour)
        }
    }

    static func item(placeId: String, database: AppDatabase) -> PlaceMapItem? {
        items(database: database).first { $0.id == placeId }
    }

    private static func pin(_ placeId: String?, _ store: RouteQueries, _ colours: [String: String]) -> PlacePin? {
        guard let placeId, let p = try? store.place(id: placeId) else { return nil }
        let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PlacePin(id: p.id, name: name.isEmpty ? RouteLabels.place(nil) : name, lat: p.lat, lon: p.lon, colourId: colours[p.id] ?? "orange")
    }

    /// F-06: the start and end place of a ride, for its map
    static func pins(rideId: String, database: AppDatabase) -> [PlacePin] {
        let store = RouteQueries(database)
        guard let link = try? store.link(rideId: rideId) else { return [] }
        let colours = PlaceColourStore.colours(database: database)
        return unique([pin(link.startPlaceId, store, colours), pin(link.endPlaceId, store, colours)])
    }

    /// F-06: the start and end place of a route, for its map
    static func pins(routeId: String, database: AppDatabase) -> [PlacePin] {
        let store = RouteQueries(database)
        guard let route = try? store.route(id: routeId) else { return [] }
        let colours = PlaceColourStore.colours(database: database)
        return unique([pin(route.fromPlaceId, store, colours), pin(route.toPlaceId, store, colours)])
    }

    private static func unique(_ pins: [PlacePin?]) -> [PlacePin] {
        var seen = Set<String>()
        return pins.compactMap { $0 }.filter { seen.insert($0.id).inserted }
    }
}

/// F-13: a place made by hand lands in the same table as the automatic ones, so ride matching treats it the same way.
enum PlaceAddService {
    /// Saves the place and its colour; returns its id.
    @discardableResult
    static func add(name: String?, lat: Double, lon: Double, radiusM: Double?, colourId: String, database: AppDatabase) throws -> String {
        let id = UUID().uuidString
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try RouteQueries(database).save(place: PlaceRecord(id: id, name: (clean?.isEmpty ?? true) ? nil : clean, lat: lat, lon: lon,
                                                           radiusM: radiusM, canCharge: false, learnedAltM: nil, createdAt: now))
        try PlaceColourStore.write(placeId: id, colourId: colourId, database: database)
        return id
    }
}
