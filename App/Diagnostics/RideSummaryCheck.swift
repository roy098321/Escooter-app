import CorckieCore
import Foundation

/// u15 (M1-13): the ride summary built from a made-up ride stored in a temporary database (the real one is never
/// touched): the numbers, the speed-coloured path with a dashed phone stretch and a walking stretch, the "recovered"
/// and heat notes, the "No GPS on this ride" case, and the delete.
enum RideSummaryCheck {
    static func run() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u15", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let store = RideQueries(temp)
            var ride = RideRecord(id: "s1", startAt: 1_790_000_000_000)
            ride.utcOffsetMin = 0
            ride.status = "recovered"
            ride.distanceM = 5_200
            ride.totalS = 1_000
            ride.movingS = 900
            ride.avgMovingMps = 5.8
            ride.topSpeedMps = 9.5
            ride.stops = 1
            ride.usedPct = 8
            ride.startRestPct = 90
            ride.endRestPct = 82
            ride.tempPeakC = 94
            ride.hasGps = true
            ride.isSimulated = true
            try store.save(ride)
            var samples: [RideSampleRecord] = []
            for i in 0..<40 {
                var s = RideSampleRecord(rideId: "s1", t: Int64(i) * 5000)
                s.lat = 40.0 + Double(i) * 0.0003
                s.lon = -75.0 + Double(i) * 0.0003
                s.hAccM = 5
                s.speedMps = 3 + Double(i % 10)
                s.batteryPct = 90 - i / 5
                s.mode = i >= 15 && i < 20 ? "phone" : (i >= 30 && i < 35 ? "walk" : "scooter")
                samples.append(s)
            }
            try store.insert(samples: samples)
            try store.replaceGaps(rideId: "s1", kind: "scooter", gaps: [(startT: 75_000, endT: 100_000)])

            guard let m = RideDetailLoader.load(id: "s1", db: temp) else {
                results.set("u15", .fail, "The stored ride could not be loaded")
                return
            }
            func stat(_ label: String) -> String? { (m.mainStats + m.scooterStats).first { $0.label == label }?.value }
            let numbersOk = stat("Distance") == "5.2 km" && stat("Time") == "17 min" && stat("Battery") == "90% \u{2192} 82%"
                && stat("Avg. speed") == "21 km/h"
            let pathOk = m.path.segments.contains { $0.dashed } && m.path.segments.contains { !$0.dashed } && m.path.walks.count == 1
            let kinds = m.notes.map(\.kind)
            let notesOk = kinds.contains(.recovered) && kinds.contains(.phone) && kinds.contains(.heat) && kinds.contains(.walk)
                && kinds.contains(.simulated)

            var bare = RideRecord(id: "s2", startAt: 1_790_100_000_000)
            bare.hasGps = false
            bare.distanceM = 3_000
            try store.save(bare)
            let noGpsOk = RideDetailLoader.load(id: "s2", db: temp)?.noGps == true

            var hidden = RideRecord(id: "s3", startAt: 1_790_200_000_000)
            hidden.kind = "discarded"
            try store.save(hidden)
            let discardedOk = RideDetailLoader.load(id: "s3", db: temp) == nil

            _ = try store.delete(rideId: "s1")
            let samplesLeft = try store.samples(rideId: "s1")
            let deleteOk = RideDetailLoader.load(id: "s1", db: temp) == nil && samplesLeft.isEmpty

            let ok = numbersOk && pathOk && notesOk && noGpsOk && discardedOk && deleteOk
            func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
            results.set("u15", ok ? .pass : .fail,
                        "Numbers \(word(numbersOk)) \u{00B7} path (dashed phone, walking) \(word(pathOk)) \u{00B7} notes \(word(notesOk)) \u{00B7} No GPS card \(word(noGpsOk)) \u{00B7} discarded hidden \(word(discardedOk)) \u{00B7} delete \(word(deleteOk))")
        } catch {
            results.set("u15", .fail, "Ride summary check failed: \(error.localizedDescription)")
        }
    }
}
