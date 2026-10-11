import CorckieCore
import Foundation
import GRDB

// M5-05: "Export everything" and Restore. The export extends the M1-16 backup: the same rows (ride, samples, stops, gaps, raw chunks)
// but lossless (every column, see `RideBundle`), plus places, routes, charges, calibration, maintenance and settings.
// Restore reads that file, a ride file from the backup folder, or a full backup, and MERGES BY RIDE (`RestorePlan`):
// nothing on the phone is overwritten or removed, nothing is added twice.

enum GzipReader {
    static func isGzip(_ d: Data) -> Bool {
        d.count > 18 && d[d.startIndex] == 0x1F && d[d.startIndex + 1] == 0x8B
    }

    /// The inverse of the backup writer's gzip frame (10-byte header, raw deflate, 8-byte trailer)
    static func gunzip(_ file: Data) throws -> Data {
        let bytes = [UInt8](file)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw CocoaError(.fileReadCorruptFile) }
        let body = Data(bytes[10..<(bytes.count - 8)])
        return try (body as NSData).decompressed(using: .zlib) as Data
    }
}

struct ExportFile: Codable {
    var app = "CorckieApp"
    var kind = "export"
    var format = 1
    var schemaVersion: Int
    var build: String
    var createdAt: Int64
    var rides: [RideBundle]
    var tables: [BundleTable]

    /// Parents first. Settings last; `merge.undo` is a note about a temporary file and is not exported.
    static let otherTables = ["scooter", "place", "route", "variant", "choice_point", "choice_option", "climb", "maintenance_item",
                              "calibration", "wheel_calibration", "charge", "fuel_price", "holiday", "setting"]
}

enum ExportAll {
    static func make(_ db: AppDatabase, build: String, nowMs: Int64) throws -> ExportFile {
        let schema = try db.appliedMigrations().count
        return try db.writer.read { d in
            let ids = try String.fetchAll(d, sql: "SELECT id FROM ride WHERE kind != 'discarded' AND isSimulated = 0 ORDER BY startAt")
            var rides: [RideBundle] = []
            for id in ids {
                if let bundle = try RideBundle.read(d, rideId: id) { rides.append(bundle) }
            }
            var tables: [BundleTable] = []
            for name in ExportFile.otherTables {
                var table = try BundleTable.read(d, table: name)
                if name == "setting", let keyIndex = table.columns.firstIndex(of: "key") {
                    table.rows = table.rows.filter { !($0[keyIndex].text ?? "").hasPrefix("merge.undo") }
                }
                tables.append(table)
            }
            return ExportFile(schemaVersion: schema, build: build, createdAt: nowMs, rides: rides, tables: tables)
        }
    }

    /// Writes the export as one JSON file; returns the number of rides and the file size.
    @discardableResult
    static func write(_ db: AppDatabase, to url: URL, build: String, nowMs: Int64) throws -> (rides: Int, bytes: Int) {
        let file = try make(db, build: build, nowMs: nowMs)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
        return (file.rides.count, data.count)
    }

    /// "CorckieApp export 2026-10-11.json"
    static func fileName(nowMs: Int64, utcOffsetMin: Int) -> String {
        "CorckieApp export \(RideQueries.dayKey(startAt: nowMs, utcOffsetMin: utcOffsetMin)).json"
    }
}

enum RestoreError: Error, LocalizedError {
    case unknownFile
    case readOnly

    var errorDescription: String? {
        switch self {
        case .unknownFile: return "This file is not a CorckieApp export or backup."
        case .readOnly: return "The database is read-only (it was written by a newer build)."
        }
    }
}

enum RestoreService {
    /// What a ride file from the backup folder holds (BackupWriter.RideDelta)
    private struct DeltaFile: Decodable {
        var app: String
        var ride: RideRecord
        var samples: [RideSampleRecord]
        var stops: [StopRecord]
        var gaps: [GapRecord]
        var chunks: [RawChunkRecord]
    }

    static func restore(_ db: AppDatabase, from url: URL) throws -> RestoreReport {
        try restore(db, data: try Data(contentsOf: url))
    }

    static func restore(_ db: AppDatabase, data raw: Data) throws -> RestoreReport {
        guard !db.isReadOnly else { throw RestoreError.readOnly }
        let data = GzipReader.isGzip(raw) ? try GzipReader.gunzip(raw) : raw
        if data.starts(with: Array("SQLite format 3".utf8)) {
            return try restoreSnapshot(db, data: data)
        }
        if let export = try? JSONDecoder().decode(ExportFile.self, from: data), export.kind == "export" {
            var report = merge(db, rides: export.rides, tables: export.tables)
            report.source = "export file"
            finish(db)
            return report
        }
        if let delta = try? JSONDecoder().decode(DeltaFile.self, from: data), delta.app == "CorckieApp" {
            var report = try restoreDelta(db, delta)
            report.source = "ride file"
            finish(db)
            return report
        }
        throw RestoreError.unknownFile
    }

    /// The newest full backup and then every ride file of a backup folder (`root` = the folder the owner picked).
    static func restoreFolder(_ db: AppDatabase, root: URL) throws -> RestoreReport {
        let dir = root.appendingPathComponent(BackupPlan.folderName, isDirectory: true)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var report = RestoreReport()
        if let full = names.last(where: { $0.hasPrefix("full-") }) {
            report = add(report, try restore(db, from: dir.appendingPathComponent(full)))
        }
        let ridesDir = dir.appendingPathComponent("rides", isDirectory: true)
        for name in ((try? fm.contentsOfDirectory(atPath: ridesDir.path)) ?? []).sorted() {
            if let one = try? restore(db, from: ridesDir.appendingPathComponent(name)) { report = add(report, one) }
        }
        report.source = "backup folder"
        return report
    }

    private static func add(_ a: RestoreReport, _ b: RestoreReport) -> RestoreReport {
        var out = a
        out.ridesAdded += b.ridesAdded
        out.ridesSkipped += b.ridesSkipped
        out.ridesFailed += b.ridesFailed
        out.otherRows += b.otherRows
        return out
    }

    // MARK: Sources

    private static func restoreSnapshot(_ db: AppDatabase, data: Data) throws -> RestoreReport {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-restore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        var config = Configuration()
        config.readonly = true
        let source = try DatabaseQueue(path: tmp.path, configuration: config)
        let (rides, tables): ([RideBundle], [BundleTable]) = try source.read { d in
            let ids = try String.fetchAll(d, sql: "SELECT id FROM ride WHERE kind != 'discarded' AND isSimulated = 0 ORDER BY startAt")
            var rides: [RideBundle] = []
            for id in ids {
                if let bundle = try RideBundle.read(d, rideId: id) { rides.append(bundle) }
            }
            var tables: [BundleTable] = []
            for name in ExportFile.otherTables {
                if let t = try? BundleTable.read(d, table: name) { tables.append(t) }
            }
            return (rides, tables)
        }
        var report = merge(db, rides: rides, tables: tables)
        report.source = "full backup"
        finish(db)
        return report
    }

    private static func restoreDelta(_ db: AppDatabase, _ delta: DeltaFile) throws -> RestoreReport {
        var report = RestoreReport()
        try db.writer.write { d in
            let existing = try existingRides(d)
            let plan = RestorePlan.decide(existing: existing, incoming: [RestoreRide(id: delta.ride.id, startAt: delta.ride.startAt, distanceM: delta.ride.distanceM)])
            guard plan.add.contains(delta.ride.id) else {
                report.ridesSkipped = 1
                return
            }
            do {
                try d.inSavepoint {
                    var ride = delta.ride
                    if let sid = ride.scooterId,
                       (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM scooter WHERE id = ?", arguments: [sid]) ?? 0) == 0 { ride.scooterId = nil }
                    try ride.insert(d)
                    for s in delta.samples { try s.insert(d) }
                    for s in delta.stops { try s.insert(d) }
                    for g in delta.gaps {
                        var gap = g
                        gap.id = nil
                        try gap.insert(d)
                    }
                    for c in delta.chunks { try c.insert(d) }
                    return .commit
                }
                report.ridesAdded = 1
            } catch {
                report.ridesFailed = 1
            }
        }
        return report
    }

    // MARK: Merge

    private static func existingRides(_ d: Database) throws -> [RestoreRide] {
        try Row.fetchAll(d, sql: "SELECT id, startAt, distanceM FROM ride").map { row in
            RestoreRide(id: row["id"], startAt: row["startAt"], distanceM: row["distanceM"])
        }
    }

    static func merge(_ db: AppDatabase, rides: [RideBundle], tables: [BundleTable]) -> RestoreReport {
        var report = RestoreReport()
        do {
            try db.writer.write { d in
                for name in ExportFile.otherTables {
                    if let table = tables.first(where: { $0.name == name }) {
                        report.otherRows += (try? table.insert(d)) ?? 0
                    }
                }
                let existing = try existingRides(d)
                let incoming = rides.map { RestoreRide(id: $0.rideId, startAt: $0.startAt ?? 0, distanceM: $0.distanceM) }
                let plan = RestorePlan.decide(existing: existing, incoming: incoming)
                report.ridesSkipped = plan.skip.count
                let wanted = Set(plan.add)
                for bundle in rides where wanted.contains(bundle.rideId) {
                    do {
                        try d.inSavepoint {
                            try bundle.insert(d)
                            return .commit
                        }
                        report.ridesAdded += 1
                    } catch {
                        report.ridesFailed += 1
                    }
                }
            }
        } catch {
            report.ridesFailed += rides.count - report.ridesAdded - report.ridesSkipped
        }
        return report
    }

    /// What depends on the rides: battery calibration and the factor numbers. Never throws.
    private static func finish(_ db: AppDatabase) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try? CalibrationUpdater.update(db, nowMs: now)
        _ = try? FactorUpdater.update(db, rideId: nil, nowMs: now)
    }
}

/// Settings → Data and backup → Delete all data. Rides, routes, places, charges and the numbers made from them go; settings, the scooter
/// pairing and the maintenance list stay. Backup files are never touched.
enum DeleteAllData {
    static let tables = ["ride", "place", "route", "charge", "calibration", "wheel_calibration", "factor_effect", "insight", "message_log",
                         "week_summary", "weather_hour", "elevation_point", "untracked_distance", "climb"]

    static func run(_ db: AppDatabase) throws {
        guard !db.isReadOnly else { throw RestoreError.readOnly }
        try db.writer.write { d in
            for name in tables { try d.execute(sql: "DELETE FROM \(name)") }
            try d.execute(sql: "DELETE FROM setting WHERE key LIKE 'trim.original.%' OR key = 'merge.undo'")
        }
    }
}
