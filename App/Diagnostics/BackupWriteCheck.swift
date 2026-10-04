import CorckieCore
import Foundation

/// u16 (M1-16): the real backup writer, into a temporary folder from a temporary database (the real data and the
/// real backup folder are not touched): a full backup and a ride delta are written, read back (gzip frame, CRC,
/// SQLite header, ride id), `latest.json` exists, and a second week prunes the oldest full.
enum BackupWriteCheck {
    static func run() {
        let results = CheckResults.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("corckie-backup-check-\(UUID().uuidString)")
        let temp: AppDatabase
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u16", .fail, "Could not set up the temporary folder: \(error.localizedDescription)")
            return
        }
        defer {
            temp.discardTemporary()
            try? fm.removeItem(at: root)
        }
        do {
            let store = RideQueries(temp)
            var ride = RideRecord(id: "b1", startAt: 1_790_000_000_000 + 3 * 7 * 86_400_000)   // the day of the last full
            ride.utcOffsetMin = 0
            ride.isSimulated = true
            ride.distanceM = 4_000
            try store.save(ride)
            var s = RideSampleRecord(rideId: "b1", t: 0)
            s.speedMps = 5
            try store.insert(samples: [s])
            let day: Int64 = 86_400_000
            let t0: Int64 = 1_790_000_000_000
            // four weekly fulls in a row: only the newest three stay
            var outcome = BackupWriter.Outcome()
            for week in 0..<4 {
                let now = t0 + Int64(week) * 7 * day
                outcome = try BackupWriter.perform(db: temp, root: root, rideId: week == 3 ? "b1" : nil, fullDue: true,
                                                   nowMs: now, offsetMin: 0)
            }
            let dir = root.appendingPathComponent(BackupPlan.folderName)
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            let fulls = names.filter { $0.hasSuffix(".corckie") }
            let prunedOk = fulls.count == BackupPlan.fullsKept && names.contains("latest.json")

            let newest = fulls.sorted().last ?? ""
            let fullData = try BackupWriter.gunzip(Data(contentsOf: dir.appendingPathComponent(newest)))
            let header = String(decoding: fullData.prefix(15), as: UTF8.self)
            let fullOk = header == "SQLite format 3"

            var rideOk = false
            if let file = outcome.rideFile {
                let packed = try Data(contentsOf: dir.appendingPathComponent("rides").appendingPathComponent(file))
                let json = try BackupWriter.gunzip(packed)
                let delta = try JSONDecoder().decode(BackupWriter.RideDelta.self, from: json)
                rideOk = delta.ride.id == "b1" && delta.samples.count == 1 && delta.rideCount == 1
            }
            let ok = prunedOk && fullOk && rideOk
            func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
            results.set("u16", ok ? .pass : .fail,
                        "Full backup read back \(word(fullOk)) \u{00B7} ride delta read back \(word(rideOk)) \u{00B7} 3 fulls kept, latest.json \(word(prunedOk))")
        } catch {
            results.set("u16", .fail, "Backup check failed: \(error.localizedDescription)")
        }
    }
}
