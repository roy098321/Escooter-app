import Foundation
import GRDB

// M2-01: places, routes and variants as plain records (DATA_MODEL section 2). No schema change: `place`, `route`,
// `variant` and `ride.routeId / variantId / startPlaceId / endPlaceId` exist in migration v1.
// App/Store is compiled into AppTests without CorckieCore, so nothing here imports it.

/// `place`: a named (or not yet named) spot.
struct PlaceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "place"

    var id: String
    var name: String?
    var lat: Double
    var lon: Double
    /// nil = automatic (5% of the trip, T60)
    var radiusM: Double?
    var canCharge: Bool = false
    var learnedAltM: Double?
    var createdAt: Int64?
}

/// `route`: A to B, one direction.
struct RouteRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "route"

    var id: String
    var fromPlaceId: String?
    var toPlaceId: String?
    var name: String?
    var usualDistanceM: Double?
    /// ride / shortHop (M36)
    var sizeClass: String?
    /// suggested / saved / dismissed
    var state: String = "suggested"
    var createdAt: Int64?
}

/// `variant`: one way of riding a route; `polyline` is the encoded path (10 m steps).
struct VariantRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "variant"

    var id: String
    var routeId: String?
    var name: String?
    var nameByHand: Bool = false
    var polyline: String?
    var isReference: Bool = false
    var isCombination: Bool = false
}

/// What the route statistics need of a ride on a route (columns of `ride`).
struct RouteRideRow: Codable, FetchableRecord, Equatable {
    var id: String
    var startAt: Int64
    var utcOffsetMin: Int?
    var kind: String
    var variantId: String?
    var totalS: Double?
    var distanceM: Double?
    var avgMovingMps: Double?
    var usedPct: Double?
    var elevGainM: Double?
    var elevLossM: Double?
    var excludedFromUsual: Bool
    var windLevel: String?
    var wet: String?
}

/// The few `ride_sample` columns the route logic reads.
struct PathSampleRow: Codable, FetchableRecord, Equatable {
    var lat: Double?
    var lon: Double?
    var hAccM: Double?
    var odometerKm: Double?
}

/// A ride's place in the route tables.
struct RideRouteLink: Equatable {
    var routeId: String?
    var variantId: String?
    var startPlaceId: String?
    var endPlaceId: String?
}
