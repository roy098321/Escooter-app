import Foundation
import GRDB

/// M2-01: reading and writing places, routes and variants, and linking rides to them. One value type over
/// `AppDatabase`, like `RideQueries`. A read-only database (V6) refuses every write.
struct RouteQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private var writer: any DatabaseWriter { database.writer }

    private func requireWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    // MARK: Reading

    func places() throws -> [PlaceRecord] {
        try writer.read { db in try PlaceRecord.order(Column("createdAt"), Column("id")).fetchAll(db) }
    }

    func routes() throws -> [RouteRecord] {
        try writer.read { db in try RouteRecord.order(Column("createdAt"), Column("id")).fetchAll(db) }
    }

    func variants() throws -> [VariantRecord] {
        try writer.read { db in try VariantRecord.order(Column("rowid")).fetchAll(db) }
    }

    func variants(routeId: String) throws -> [VariantRecord] {
        try writer.read { db in try VariantRecord.filter(Column("routeId") == routeId).order(Column("rowid")).fetchAll(db) }
    }

    func place(id: String) throws -> PlaceRecord? {
        try writer.read { db in try PlaceRecord.fetchOne(db, key: id) }
    }

    func route(id: String) throws -> RouteRecord? {
        try writer.read { db in try RouteRecord.fetchOne(db, key: id) }
    }

    /// Creation order of the route among all routes (1-based), for the "Route 3" fallback name.
    func ordinal(ofRoute id: String) throws -> Int {
        let all = try routes()
        return (all.firstIndex { $0.id == id } ?? 0) + 1
    }

    func counts() throws -> (places: Int, routes: Int, variants: Int) {
        try writer.read { db in
            (try PlaceRecord.fetchCount(db), try RouteRecord.fetchCount(db), try VariantRecord.fetchCount(db))
        }
    }

    /// The ride's links into the route tables.
    func link(rideId: String) throws -> RideRouteLink? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT routeId, variantId, startPlaceId, endPlaceId FROM ride WHERE id = ?",
                                             arguments: [rideId]) else { return nil }
            return RideRouteLink(routeId: row["routeId"], variantId: row["variantId"], startPlaceId: row["startPlaceId"],
                                 endPlaceId: row["endPlaceId"])
        }
    }

    /// Rides on a route, newest first (discarded pieces never).
    func routeRides(routeId: String) throws -> [RouteRideRow] {
        try writer.read { db in
            try RouteRideRow.fetchAll(db, sql: """
                SELECT id, startAt, utcOffsetMin, kind, variantId, totalS, distanceM, avgMovingMps, usedPct, elevGainM, elevLossM,
                       excludedFromUsual, windLevel, wet
                FROM ride WHERE routeId = ? AND kind != 'discarded' ORDER BY startAt DESC
                """, arguments: [routeId])
        }
    }

    func rideCount(routeId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ride WHERE routeId = ? AND kind != 'discarded'", arguments: [routeId]) ?? 0
        }
    }

    /// Finished rides that are not on any route yet and have GPS (candidates for a "same trip" match), newest first.
    func unassignedRides(limit: Int, excluding rideId: String, simulated: Bool) throws -> [RideRecord] {
        try writer.read { db in
            try RideRecord.fetchAll(db, sql: """
                SELECT * FROM ride
                WHERE routeId IS NULL AND id != ? AND kind != 'discarded' AND status != 'recording' AND hasGps = 1
                  AND assignedByHand = 0 AND isSimulated = ?
                ORDER BY startAt DESC LIMIT ?
                """, arguments: [rideId, simulated, limit])
        }
    }

    func pathSamples(rideId: String) throws -> [PathSampleRow] {
        try writer.read { db in
            try PathSampleRow.fetchAll(db, sql: "SELECT lat, lon, hAccM, odometerKm FROM ride_sample WHERE rideId = ? ORDER BY t",
                                       arguments: [rideId])
        }
    }

    // MARK: Writing

    func save(place: PlaceRecord) throws {
        try requireWritable()
        try writer.write { db in try place.upsert(db) }
    }

    func save(route: RouteRecord) throws {
        try requireWritable()
        try writer.write { db in try route.upsert(db) }
    }

    func save(variant: VariantRecord) throws {
        try requireWritable()
        try writer.write { db in try variant.upsert(db) }
    }

    /// Puts a ride on a route (and its variant and places).
    func setLink(rideId: String, _ link: RideRouteLink) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE ride SET routeId = ?, variantId = ?, startPlaceId = ?, endPlaceId = ? WHERE id = ?",
                           arguments: [link.routeId, link.variantId, link.startPlaceId, link.endPlaceId, rideId])
        }
    }

    /// M36: rides on a saved route take the route's size class.
    func setRideKind(rideId: String, kind: String) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE ride SET kind = ? WHERE id = ? AND kind IN ('ride', 'shortHop')", arguments: [kind, rideId])
        }
    }

    func setUsualDistance(routeId: String, distanceM: Double) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE route SET usualDistanceM = ? WHERE id = ?", arguments: [distanceM, routeId])
        }
    }

    func setState(routeId: String, state: String) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE route SET state = ? WHERE id = ?", arguments: [state, routeId])
        }
    }

    /// nil or empty clears the owner's name (the name made from the places shows again).
    func rename(routeId: String, name: String?) throws {
        try requireWritable()
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(sql: "UPDATE route SET name = ? WHERE id = ?", arguments: [(clean?.isEmpty ?? true) ? nil : clean, routeId])
        }
    }

    func rename(placeId: String, name: String?) throws {
        try requireWritable()
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(sql: "UPDATE place SET name = ? WHERE id = ?", arguments: [(clean?.isEmpty ?? true) ? nil : clean, placeId])
        }
    }

    /// M2-05: the circle of a place in metres; nil = automatic (5% of the trip, T60).
    func setRadius(placeId: String, radiusM: Double?) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE place SET radiusM = ? WHERE id = ?", arguments: [radiusM, placeId])
        }
    }

    /// M2-05: "I can charge here" (M27: only the way there has to fit).
    func setCanCharge(placeId: String, canCharge: Bool) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE place SET canCharge = ? WHERE id = ?", arguments: [canCharge, placeId])
        }
    }


    /// A name typed by the owner is final; a street name from the phone (`byHand` false) may be replaced later.
    func rename(variantId: String, name: String, byHand: Bool) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE variant SET name = ?, nameByHand = ? WHERE id = ?", arguments: [name, byHand, variantId])
        }
    }

    /// The route's rides lose their route (the route row stays, e.g. `dismissed`, or goes with `deleteRoute`).
    func detachRides(routeId: String) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE ride SET routeId = NULL, variantId = NULL, startPlaceId = NULL, endPlaceId = NULL WHERE routeId = ?",
                           arguments: [routeId])
        }
    }

    /// Removes a route and its variants; its rides stay (in Rides) without a route.
    func deleteRoute(id: String) throws {
        try requireWritable()
        try detachRides(routeId: id)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM variant WHERE routeId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM route WHERE id = ?", arguments: [id])
        }
    }
}
