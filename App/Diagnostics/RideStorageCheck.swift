import Foundation

/// u4 (M1-08): ride storage works on the real schema and the simulator's temporary database
/// never touches the real one. Writes a small ride into a temporary database, reads it back,
/// deletes it, and compares the real database's ride count before and after.
enum RideStorageCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u4", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let realBefore = try real.map { try RideQueries($0).rides(includeDiscarded: true).count }
            let store = RideQueries(temp)
            var ride = RideRecord(startAt: Int64(Date().timeIntervalSince1970 * 1000))
            ride.isSimulated = true
            ride.createdBuild = AppInfo.build
            try store.save(ride)
            var samples: [RideSampleRecord] = []
            for i in 0..<120 {
                var s = RideSampleRecord(rideId: ride.id, t: Int64(i) * 5_000)
                s.speedMps = 5
                s.voltage = 50
                s.batteryPct = 90
                s.odometerKm = 100 + Double(i) / 100
                samples.append(s)
            }
            try store.insert(samples: samples)
            try store.insert(chunk: RawChunkRecord(rideId: ride.id, seq: 0, startAt: 0, endAt: 30_000, kind: "scooter", blob: Data([1, 2, 3])))
            let gap = try store.openGap(rideId: ride.id, kind: "scooter", startT: 60_000)
            if let id = gap.id { try store.closeGap(id: id, endT: 90_000) }
            try store.save(stop: StopRecord(rideId: ride.id, startT: 30_000, endT: 40_000))

            let readBack = try store.sampleCount(rideId: ride.id) == 120
                && store.chunks(rideId: ride.id).count == 1
                && store.gaps(rideId: ride.id).first?.endT == 90_000
                && store.stops(rideId: ride.id).count == 1
                && store.ride(id: ride.id) == ride
            _ = try store.delete(rideId: ride.id)
            let gone = try store.sampleCount(rideId: ride.id) == 0 && store.gaps(rideId: ride.id).isEmpty
            let realAfter = try real.map { try RideQueries($0).rides(includeDiscarded: true).count }
            let apart = realBefore == realAfter && temp.url != real?.url
            let ok = readBack && gone && apart
            results.set("u4", ok ? .pass : .fail,
                        "Ride + 120 samples + raw chunk + gap + stop written, read back, deleted (\(gone ? "all gone" : "left over")); real database rides \(realBefore.map(String.init) ?? "?") before / \(realAfter.map(String.init) ?? "?") after")
        } catch {
            results.set("u4", .fail, "Storage failed: \(error.localizedDescription)")
        }
    }
}
