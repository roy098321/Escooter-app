import CorckieCore
import Foundation
import GRDB

/// Note 18: each place's drawn outline lives in the `setting` table ("place.outline.<placeId>" = JSON points; no schema change), and
/// "Around <place>" rides in one setting ("rides.around" = {rideId: placeId}). Compiled into AppTests too (RouteProcessor uses it).
enum PlaceOutlineStore {
    static let aroundKey = "rides.around"

    /// Every outline, by place id (only valid ones)
    static func all(_ database: AppDatabase) -> [String: [GeoPoint]] {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT key, json FROM setting WHERE key LIKE ?", arguments: [PlaceOutline.keyPrefix + "%"])
        }) ?? []
        var out: [String: [GeoPoint]] = [:]
        for r in rows {
            let key: String = r["key"]
            if let poly = PlaceOutline.parse(r["json"]) { out[String(key.dropFirst(PlaceOutline.keyPrefix.count))] = poly }
        }
        return out
    }

    static func outline(_ database: AppDatabase, placeId: String) -> [GeoPoint]? {
        PlaceOutline.parse(try? RideQueries(database).setting(key: PlaceOutline.key(placeId: placeId)))
    }

    /// nil or fewer than 3 points = back to the circle
    static func save(_ database: AppDatabase, placeId: String, outline: [GeoPoint]?) throws {
        guard !database.isReadOnly else { return }
        let key = PlaceOutline.key(placeId: placeId)
        if let poly = outline, PlaceOutline.isValid(poly) {
            try RideQueries(database).setSetting(key: key, json: PlaceOutline.json(poly))
        } else {
            try database.writer.write { db in try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key]) }
        }
    }

    // MARK: Around rides

    static func around(_ database: AppDatabase) -> [String: String] {
        guard let json = try? RideQueries(database).setting(key: aroundKey), let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// The ride is (placeId) or is no longer (nil) an "Around" ride
    static func setAround(_ database: AppDatabase, rideId: String, placeId: String?) throws {
        var map = around(database)
        guard map[rideId] != placeId else { return }
        map[rideId] = placeId
        let data = try JSONEncoder().encode(map)
        try RideQueries(database).setSetting(key: aroundKey, json: String(data: data, encoding: .utf8) ?? "{}")
    }
}
