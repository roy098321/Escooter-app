import CorckieCore
import CorckieSim
import Foundation

/// Made-up rides on the synthetic map (CorckieSim `SyntheticRoutes`: open sea, no real place) written straight into a database,
/// for the in-app checks (u17 ...) and the app-tests. Compiled into AppTests too. Never used on the real database.
enum RouteFixtures {
    /// One finished ride along `path` (waypoints in metres on the fake map): a sample every 5 s at 7 m/s, GPS good (5 m) unless
    /// `gpsFrom...gpsTo` seconds are left without a fix, battery down 6%.
    @discardableResult
    static func insertRide(_ db: AppDatabase, id: String, path: [SyntheticRoutes.XY], startAt: Int64, simulated: Bool = true,
                           noGpsFirstSeconds: Int = 0, elevGainM: Double = 30, timeS: Double? = nil) throws -> String {
        let total = SyntheticRoutes.pathLength(path)
        let seconds = timeS ?? (total / 7).rounded()
        let count = Int(seconds / 5) + 1
        let rides = RideQueries(db)
        var ride = RideRecord(id: id, startAt: startAt)
        ride.status = "ended"
        ride.kind = RideSizeClass.of(distanceM: total).rawValue
        ride.utcOffsetMin = 0
        ride.endAt = startAt + Int64(seconds * 1000)
        ride.distanceM = (total / 100).rounded() * 100
        ride.totalS = seconds
        ride.movingS = seconds
        ride.avgMovingMps = total / max(1, seconds)
        ride.topSpeedMps = 7
        ride.usedPct = 6
        ride.startRestPct = 90
        ride.endRestPct = 84
        ride.elevGainM = elevGainM
        ride.elevLossM = elevGainM
        ride.hasGps = true
        ride.isSimulated = simulated
        ride.createdBuild = "fixture"
        try rides.save(ride)
        var samples: [RideSampleRecord] = []
        for i in 0..<count {
            let t = Double(i) * 5
            let d = min(total, total * t / seconds)
            let p = SyntheticRoutes.point(on: path, at: d)
            let c = SyntheticRoutes.coordinate(p)
            var s = RideSampleRecord(rideId: id, t: Int64(t * 1000))
            if Int(t) >= noGpsFirstSeconds {
                s.lat = c.lat
                s.lon = c.lon
                s.hAccM = 5
            }
            s.speedMps = 7
            s.batteryPct = 90 - Int((6 * d / max(1, total)).rounded())
            s.odometerKm = ((100 + d / 1000) * 10).rounded() / 10
            s.mode = "scooter"
            s.moving = true
            samples.append(s)
        }
        try rides.insert(samples: samples)
        return id
    }
}

