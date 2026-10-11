import CorckieCore
import Foundation

/// M5: made-up rides in the ocean for the u38 / u40 checks and the app-tests (never on the real database).
/// 100 samples 5 s apart at 18 km/h, odometer +0.025 km per sample, 216 W, battery falling 1 point per 20 samples.
enum RideToolsSeed {
    static let lon = -30.0

    static func ride(_ db: AppDatabase, id: String, startAt: Int64, n: Int = 100, odoStartKm: Double = 100, lat0: Double = 10.0,
                     battery: Int = 80, simulated: Bool = false) throws {
        let q = RideQueries(db)
        var r = RideRecord(id: id, startAt: startAt)
        r.status = "ended"
        r.kind = "ride"
        r.utcOffsetMin = 180
        r.hasGps = true
        r.isSimulated = simulated
        r.endAt = startAt + Int64(max(n - 1, 0)) * 5_000
        r.endReason = "held"
        r.createdBuild = "test"
        try q.save(r)
        var rows: [RideSampleRecord] = []
        for i in 0..<n {
            var s = RideSampleRecord(rideId: id, t: Int64(i) * 5_000)
            s.speedMps = 5
            s.gpsSpeedMps = 5
            s.lat = lat0 + Double(i) * 0.000_2
            s.lon = lon
            s.hAccM = 5
            s.altBaroM = 50 + Double(i) * 0.1
            s.voltage = 54
            s.currentA = 4
            s.powerW = 216
            s.batteryPct = battery - i / 20
            s.tempC = 30
            s.odometerKm = odoStartKm + Double(i) * 0.025
            s.mode = "scooter"
            rows.append(s)
        }
        try q.insert(samples: rows)
        try RideToolsService.recompute(db, rideId: id, reclass: true)
    }
}
