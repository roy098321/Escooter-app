import CorckieCore
import Foundation
import GRDB

/// F-39 flaw 6: arrived = the ride's last movement is inside the place's circle. When rides keep ending just outside it (2 rides
/// within 2× its radius), the place screen offers "Your rides end a bit outside Uni. Widen it?" (one tap, never silent).
enum PlaceWiden {
    /// How many recent rides are looked at
    static let recentRides = 40

    /// The wider circle to offer for this place, nil = no offer
    static func suggestion(placeId: String, database: AppDatabase) -> Double? {
        guard let place = try? RouteQueries(database).place(id: placeId) else { return nil }
        let radius = place.radiusM ?? PlaceHere.automaticRadiusM
        let ends: [(lat: Double, lon: Double)] = (try? database.writer.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM ride WHERE isSimulated = 0 AND kind != 'discarded' AND endAt IS NOT NULL ORDER BY startAt DESC LIMIT ?
                """, arguments: [recentRides])
            return try ids.compactMap { id -> (lat: Double, lon: Double)? in
                guard let row = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL ORDER BY t DESC LIMIT 1",
                                                 arguments: [id]) else { return nil }
                let lat: Double? = row["lat"]
                let lon: Double? = row["lon"]
                guard let lat, let lon else { return nil }
                return (lat, lon)
            }
        }) ?? []
        let centre = GeoPoint(lat: place.lat, lon: place.lon)
        let distances = ends.map { Geo.distanceM(centre, GeoPoint(lat: $0.lat, lon: $0.lon)) }
        return TripRules.widenRadius(endDistancesM: distances, radiusM: radius, choices: PlaceListBuilder.radiusChoices)
    }
}
