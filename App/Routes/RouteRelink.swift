import CorckieCore
import Foundation
import GRDB

// B24 (T-04): up to build 164 a ride got its start / end place only through a saved route, and the way back of a route
// (Work → Home after Home → Work) waited for a second trip, so the estimates never reached the 3 / 5 rides they need.
// Ride close now sets the places from the circles and offers the way back at once (`RouteBook`); this one-off pass runs
// the stored rides through the same `RouteProcessor` once after the update. It only fills links and adds places / routes /
// variants: no row is ever deleted (update check a9). Compiled into AppTests too.

struct RelinkResult: Equatable {
    /// Rides looked at (finished, not discarded, not a merged piece)
    var rides: Int
    var placedBefore: Int
    var placedAfter: Int
    var routedBefore: Int
    var routedAfter: Int
    var routesBefore: Int
    var routesAfter: Int
    var milliseconds: Int

    var line: String {
        "\(rides) rides · with a place \(placedBefore) → \(placedAfter) · on a route \(routedBefore) → \(routedAfter) · routes \(routesBefore) → \(routesAfter) · \(milliseconds) ms"
    }

    var json: String {
        "{\"rides\":\(rides),\"placedBefore\":\(placedBefore),\"placedAfter\":\(placedAfter),\"routedBefore\":\(routedBefore),"
            + "\"routedAfter\":\(routedAfter),\"routesBefore\":\(routesBefore),\"routesAfter\":\(routesAfter),\"ms\":\(milliseconds)}"
    }
}

enum RouteRelink {
    /// The `setting` row that says the pass has run (its JSON = the result, shown by check u51 and in the export)
    static let settingKey = "b24.relink"

    /// Runs the pass once per database; nil when it already ran (or the database is read-only).
    @discardableResult
    static func runOnce(database: AppDatabase, log: (String) -> Void = { _ in }) throws -> RelinkResult? {
        guard !database.isReadOnly else { return nil }
        let rides = RideQueries(database)
        if try rides.setting(key: settingKey) != nil { return nil }
        let result = try run(database: database)
        try rides.setSetting(key: settingKey, json: result.json)
        log("Re-link of stored rides (B24): " + result.line)
        return result
    }

    /// B61 layer 1: every saved route is linked to the named place its end falls inside ("where you ended counts", as in note 7), so its
    /// row and the place's row are one. Only `route.toPlaceId` changes, no row is removed. Returns how many routes were linked.
    @discardableResult
    static func linkRouteEnds(database: AppDatabase) throws -> Int {
        guard !database.isReadOnly else { return 0 }
        let store = RouteQueries(database)
        let named = try store.places().filter { !($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .map { WhereToDedupe.NamedPlace(id: $0.id, name: $0.name ?? "", center: GeoPoint(lat: $0.lat, lon: $0.lon), radiusM: $0.radiusM) }
        guard !named.isEmpty else { return 0 }
        var changed = 0
        for var route in try store.routes() where route.state == "saved" {
            guard let to = WhereToDedupe.relink(toPlaceId: route.toPlaceId, end: QuickDialLoader.routeEnd(route, store: store), places: named) else { continue }
            route.toPlaceId = to
            try store.save(route: route)
            changed += 1
        }
        return changed
    }

    private struct RelinkRow: Decodable, FetchableRecord {
        var id: String
        var routeId: String?
        var startPlaceId: String?
        var endPlaceId: String?
        var assignedByHand: Bool
    }

    /// Oldest first, so places and routes appear in the order the rides happened. Safe to run again: rides on a route are left
    /// as they are (only a missing place is filled from the route), every other ride goes through ride-close processing again.
    static func run(database: AppDatabase) throws -> RelinkResult {
        let started = Date()
        let store = RouteQueries(database)
        func load() throws -> [RelinkRow] {
            try database.writer.read { db in
                try RelinkRow.fetchAll(db, sql: """
                    SELECT id, routeId, startPlaceId, endPlaceId, assignedByHand FROM ride
                    WHERE kind != 'discarded' AND status != 'recording' AND mergeGroupId IS NULL
                    ORDER BY startAt, id
                    """)
            }
        }
        let before = try load()
        let routesBefore = try store.counts().routes
        for row in before {
            if let routeId = row.routeId {
                if row.startPlaceId == nil || row.endPlaceId == nil, let route = try store.route(id: routeId) {
                    try store.setPlaces(rideId: row.id, startPlaceId: row.startPlaceId ?? route.fromPlaceId,
                                        endPlaceId: row.endPlaceId ?? route.toPlaceId)
                }
                continue
            }
            if row.assignedByHand { continue }
            // an earlier ride of this pass may already have taken this one onto a new route (the same trip twice)
            if try store.link(rideId: row.id)?.routeId != nil { continue }
            try RouteProcessor.process(rideId: row.id, database: database)
        }
        let after = try load()
        func placed(_ rows: [RelinkRow]) -> Int { rows.filter { $0.startPlaceId != nil || $0.endPlaceId != nil }.count }
        return RelinkResult(rides: before.count, placedBefore: placed(before), placedAfter: placed(after),
                            routedBefore: before.filter { $0.routeId != nil }.count, routedAfter: after.filter { $0.routeId != nil }.count,
                            routesBefore: routesBefore, routesAfter: try store.counts().routes,
                            milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
