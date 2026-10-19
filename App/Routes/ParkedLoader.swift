import CorckieCore
import Foundation
import GRDB

/// V17: where the scooter was last parked, read from what the last finished ride already stored: its last GPS sample, else its end place.
/// Reads only. Simulated rides count only while a simulation is shown (the caller says so; this file is also compiled into AppTests).
enum ParkedLoader {
    static func latest(database: AppDatabase, simulated: Bool) -> ParkedSpot? {
        let spot: ParkedSpot? = try? database.writer.read { (db: Database) -> ParkedSpot? in
            guard let ride = try Row.fetchOne(db, sql: """
                SELECT id, endAt, endPlaceId FROM ride
                WHERE kind IN ('ride', 'shortHop') AND endAt IS NOT NULL AND isSimulated = ?
                ORDER BY endAt DESC LIMIT 1
                """, arguments: [simulated ? 1 : 0]) else { return nil }
            let id: String = ride["id"]
            let endAt: Int64 = ride["endAt"]
            let placeId: String? = ride["endPlaceId"]
            var placeName: String?
            var placeLat: Double?
            var placeLon: Double?
            if let placeId, let p = try Row.fetchOne(db, sql: "SELECT name, lat, lon FROM place WHERE id = ?", arguments: [placeId]) {
                let name: String? = p["name"]
                placeName = name
                placeLat = p["lat"]
                placeLon = p["lon"]
            }
            if let last = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY t DESC LIMIT 1",
                                           arguments: [id]) {
                let lat: Double? = last["lat"]
                let lon: Double? = last["lon"]
                if let lat, let lon { return ParkedSpot(lat: lat, lon: lon, endedAtMs: endAt, placeName: placeName) }
            }
            if let placeLat, let placeLon {
                return ParkedSpot(lat: placeLat, lon: placeLon, endedAtMs: endAt, placeName: placeName)
            }
            return nil
        }
        return spot
    }
}
