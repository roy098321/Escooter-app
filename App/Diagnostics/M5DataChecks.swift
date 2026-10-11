import CorckieCore
import Foundation
import GRDB

/// u40 (M5-05): Export everything and Restore in temporary databases: three made-up rides + a setting go out and come back,
/// restoring twice adds nothing, a changed ride is not overwritten, a ride that is already there under another id is skipped, a full backup
/// file is a source too; ends with this phone's ride count.
enum ExportRestoreCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        do {
            let a = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { a.discardTemporary() }
            let b = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { b.discardTemporary() }
            let c = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { c.discardTemporary() }
            let d = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { d.discardTemporary() }
            let t0: Int64 = 1_790_000_000_000
            try RideToolsSeed.ride(a, id: "R1", startAt: t0)
            try RideToolsSeed.ride(a, id: "R2", startAt: t0 + 5 * 3_600_000, n: 60)
            try RideToolsSeed.ride(a, id: "R3", startAt: t0 + 86_400_000)
            try RideQueries(a).setSetting(key: "check.u40", json: "7")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-u40-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let written = try ExportAll.write(a, to: file, build: AppInfo.build, nowMs: t0)
            let first = try RestoreService.restore(b, from: file)
            let samples = try count(b, "ride_sample")
            let setting = try RideQueries(b).setting(key: "check.u40")
            let b1: Bool = written.rides == 3 && first.ridesAdded == 3
            let b2: Bool = samples == 260 && setting == "7"
            let backOk = b1 && b2

            try b.writer.write { try $0.execute(sql: "UPDATE ride SET usedPct = 99 WHERE id = 'R1'") }
            let again = try RestoreService.restore(b, from: file)
            let usedKept: Bool = try RideQueries(b).ride(id: "R1")?.usedPct == 99
            let rideCount = try count(b, "ride")
            let t1: Bool = again.ridesAdded == 0 && again.ridesSkipped == 3
            let twiceOk = t1 && usedKept && rideCount == 3

            try RideToolsSeed.ride(c, id: "OTHER", startAt: t0)
            let sameRide = try RestoreService.restore(c, from: file)
            let otherIdOk: Bool = sameRide.ridesAdded == 2 && sameRide.ridesSkipped == 1

            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-u40-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try a.writeSnapshot(to: snapshot)
            let full = try RestoreService.restore(d, data: try Data(contentsOf: snapshot))
            let fullOk: Bool = full.ridesAdded == 3 && full.source == "full backup"

            var phone = "no data"
            if let real, let n = try? count(real, "ride") { phone = "\(n) rides" }
            let all = backOk && twiceOk && otherIdOk && fullOk
            results.set("u40", all ? .pass : .fail,
                        "export + restore \(word(backOk)) · restoring twice adds nothing, a changed ride is kept \(word(twiceOk)) · same ride under another id skipped \(word(otherIdOk)) · full backup as a source \(word(fullOk)) · this phone: \(phone)")
        } catch {
            results.set("u40", .fail, "The temporary database failed: \(error.localizedDescription)")
        }
    }

    private static func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}

/// u41 (M5-06 / M5-07): the Settings list is the C23 list with the real defaults, a new battery size reaches the calibration, the four
/// notification switches and the load levels are read back, raw data retention keeps the energy chunks and every summary.
enum SettingsCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let titles = SettingsCatalog.groups.map(\.title)
        let expected = ["Battery and charging", "Units and display", "Costs", "Rider", "Voice and notifications", "Places", "Data and backup", "Help", "Developer"]
        let listOk: Bool = titles == expected
        let d1: Bool = SettingsCatalog.row("battery.packAh")?.defaultText == "16 Ah"
        let d2: Bool = SettingsCatalog.row("battery.chargerA")?.defaultText == "2.0 A"
        let d3: Bool = SettingsCatalog.row("data.rawRetention")?.defaultText == "90 days"
        let defaultsOk = d1 && d2 && d3
        let day: Int64 = 86_400_000
        let now: Int64 = 1_800_000_000_000
        let p1: Bool = RawRetention.days90.deletes(kind: "scooter", endAtMs: now - 91 * day, nowMs: now)
        let p2: Bool = !RawRetention.days90.deletes(kind: "energy", endAtMs: now - 900 * day, nowMs: now)
        let p3: Bool = !RawRetention.forever.deletes(kind: "scooter", endAtMs: now - 5_000 * day, nowMs: now)
        let planOk = p1 && p2 && p3
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try RideToolsSeed.ride(temp, id: "R1", startAt: now - 200 * day)
            let q = RideQueries(temp)
            try q.insert(chunk: RawChunkRecord(rideId: "R1", seq: 0, startAt: now - 200 * day, endAt: now - 199 * day, kind: "scooter", blob: Data([1])))
            try q.insert(chunk: RawChunkRecord(rideId: "R1", seq: 1, startAt: now - 200 * day, endAt: now - 199 * day, kind: "energy", blob: Data([1])))
            let deleted = try RetentionService.run(temp, nowMs: now)
            let left = try temp.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM raw_chunk") ?? 0 }
            let rides = try temp.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") ?? 0 }
            let retentionOk: Bool = deleted == 1 && left == 1 && rides == 1

            BatterySettings.setPackAh(temp, 13, nowMs: now)
            let batteryOk: Bool = CalibrationUpdater.current(temp).packAh == 13 && BatterySettings.packAh(temp) == 13

            NotifyPrefs.set(temp, .weekly, false)
            let n1: Bool = !NotifyPrefs.isOn(temp, .weekly)
            let n2: Bool = NotifyPrefs.isOn(temp, .wind) && NotifyPrefs.isOn(temp, .maintenance)
            let notifyOk = n1 && n2

            SettingsValue.set(temp, RiderSettings.lightKey, "6")
            let loadOk: Bool = RiderSettings.kg(temp, .light) == 6 && RiderSettings.kg(temp, .heavy) == 15

            var phone = "no data"
            if let real {
                let u = RetentionService.usage(real)
                phone = "keeps raw data \(RetentionService.current(real).rawValue), \(u.chunks) raw chunks (\(u.bytes / 1_000) kB), battery \(Int(BatterySettings.packAh(real))) Ah"
            }
            let all = listOk && defaultsOk && planOk && retentionOk && batteryOk && notifyOk && loadOk
            results.set("u41", all ? .pass : .fail,
                        "the C23 groups in order \(word(listOk)) · defaults 16 Ah / 2.0 A / 90 days \(word(defaultsOk)) · retention plan \(word(planOk)) · retention run keeps energy chunks and every ride \(word(retentionOk)) · battery size reaches the calibration \(word(batteryOk)) · notification switches \(word(notifyOk)) · load levels \(word(loadOk)) · this phone: \(phone)")
        } catch {
            results.set("u41", .fail, "The temporary database failed: \(error.localizedDescription)")
        }
    }
}
