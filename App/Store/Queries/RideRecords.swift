import Foundation
import GRDB

// M1-08: the ride tables of migration v1 as plain records (DATA_MODEL section 2). No schema change:
// every column used here already exists. Times: `startAt` / `endAt` ... are epoch milliseconds,
// `ride_sample.t` is milliseconds from the ride start (DATA_MODEL section 2). The records only carry the
// columns M1 writes; other v1 columns keep their defaults and are never touched by an update.
// App/Store is compiled into AppTests without CorckieCore, so nothing here imports it.

/// `ride`: one row per ride, short hop or held discarded piece.
struct RideRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "ride"

    var id: String
    var scooterId: String?
    /// ride / shortHop / discarded
    var kind: String = "ride"
    /// recording / ended / recovered
    var status: String = "recording"
    var startAt: Int64
    var endAt: Int64?
    var firstMoveAt: Int64?
    var lastMoveAt: Int64?
    var utcOffsetMin: Int?
    /// disconnected / held / standstill / scooterOff / recovered
    var endReason: String?
    var mergeGroupId: String?
    var distanceM: Double?
    var totalS: Double?
    var movingS: Double?
    var avgMovingMps: Double?
    var topSpeedMps: Double?
    var stops: Int?
    var energyWhRaw: Double?
    /// M3-01: E_raw ÷ k once the battery is calibrated (M8), else nil
    var energyWhCal: Double?
    var usedPct: Double?
    var usedPctMethod: String?
    var startRestPct: Double?
    var endRestPct: Double?
    var odoStartKm: Double?
    var odoEndKm: Double?
    var elevGainM: Double?
    var elevLossM: Double?
    var elevProvisional: Bool?
    var tempStartC: Double?
    var tempPeakC: Double?
    var tempRiseC: Double?
    var gapScooterS: Double?
    var gapGpsS: Double?
    var ignoredReadings: Int = 0
    var hasGps: Bool?
    var isSimulated: Bool = false
    var createdBuild: String?

    init(id: String = UUID().uuidString, startAt: Int64) {
        self.id = id
        self.startAt = startAt
    }

    var isOpen: Bool { status == "recording" }
}

/// `ride_sample`: a timed row of everything known at that moment.
struct RideSampleRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "ride_sample"
    /// Writing the same (ride, t) again replaces it, so a recovered ride can resume safely
    /// (ride_sample has no child tables, so REPLACE removes nothing else).
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)

    var rideId: String
    /// ms from the ride start
    var t: Int64
    var speedMps: Double?
    var gpsSpeedMps: Double?
    var lat: Double?
    var lon: Double?
    var hAccM: Double?
    var altBaroM: Double?
    var voltage: Double?
    var currentA: Double?
    var powerW: Double?
    var batteryPct: Int?
    var tempC: Double?
    var odometerKm: Double?
    /// scooter / phone
    var mode: String?
    var moving: Bool?
    var stopId: String?
    /// cumulative, M5
    var distanceM: Double?

    init(rideId: String, t: Int64) {
        self.rideId = rideId
        self.t = t
    }
}

/// `raw_chunk`: compressed raw data, ~30 s per chunk.
struct RawChunkRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "raw_chunk"

    var id: String = UUID().uuidString
    var rideId: String?
    var seq: Int
    var startAt: Int64
    var endAt: Int64
    /// scooter / phone / energy
    var kind: String
    var codec: String = "zlib-v1"
    var blob: Data
}

/// `gap`: a missing stretch (pattern X). `endT == nil` while it is still open.
struct GapRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "gap"

    var id: Int64?
    var rideId: String
    /// scooter / gps
    var kind: String
    var startT: Int64
    var endT: Int64?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `stop`: a standstill inside a ride (M3).
struct StopRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "stop"

    var id: String = UUID().uuidString
    var rideId: String
    var startT: Int64
    var endT: Int64?
    var lat: Double?
    var lon: Double?
}
