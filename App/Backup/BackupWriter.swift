import CorckieCore
import Foundation
import GRDB
import Observation
import UIKit

/// M1-16 (D1 S123): backups from M1 on, to the folder picked in P4 (d2 / d3). A ride delta after every ride, a full
/// backup when the last one is 7 days old or more (at ride end or when Home opens), `latest.json` with the settings.
/// Layout and rules: DATA_MODEL section 5, `BackupPlan` in CorckieCore. Restore stays in M5.
/// Files are a gzip frame around Apple's raw deflate, so a renamed `.gz` opens in 7-Zip.
@Observable
final class BackupWriter {
    static let shared = BackupWriter()

    private(set) var lastBackupMs: Int64?
    private(set) var lastFullMs: Int64?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let queue = DispatchQueue(label: "corckie.backup", qos: .utility)
    @ObservationIgnored private var busy = false

    private init() {
        lastBackupMs = defaults.object(forKey: "corckie.lastBackupMs") as? Int64
        lastFullMs = defaults.object(forKey: "corckie.lastFullBackupMs") as? Int64
    }

    // MARK: Triggers (main thread)

    /// A ride was closed: its delta, plus a full backup when one is due.
    func rideEnded(rideId: String) { start(rideId: rideId) }

    /// Home opened: a full backup when one is due (no timers, C13 S1).
    func runIfDue() {
        if BackupPlan.fullDue(lastFullMs: lastFullMs, nowMs: Self.nowMs()) { start(rideId: nil) }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func start(rideId: String?) {
        guard !busy, BackupFolder.shared.hasFolder, let db = AppModel.shared.database else { return }
        busy = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "corckie-backup", expirationHandler: nil)
        let now = Self.nowMs()
        let offset = TimeZone.current.secondsFromGMT() / 60
        let fullDue = BackupPlan.fullDue(lastFullMs: lastFullMs, nowMs: now)
        queue.async {
            let result = Result<Outcome, Error> {
                try BackupFolder.shared.withFolder { root in
                    try Self.perform(db: db, root: root, rideId: rideId, fullDue: fullDue, nowMs: now, offsetMin: offset)
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case let .success(o):
                    self.lastError = nil
                    self.lastBackupMs = now
                    self.defaults.set(now, forKey: "corckie.lastBackupMs")
                    if o.fullName != nil {
                        self.lastFullMs = now
                        self.defaults.set(now, forKey: "corckie.lastFullBackupMs")
                    }
                    if let name = o.rideFile, !o.simulated {
                        CheckResults.shared.set("d10", .pass, "Backup written after a real ride: \(name)")
                    }
                    Log.info(source: "backup", "Backup written (\(o.fullName ?? "ride delta only"))")
                case let .failure(error):
                    self.lastError = error.localizedDescription
                    if rideId != nil { CheckResults.shared.set("d10", .fail, error.localizedDescription) }
                    Log.error(source: "backup", "Backup failed: \(error.localizedDescription)")
                }
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    // MARK: Writing (any thread)

    struct Outcome {
        var fullName: String?
        var rideFile: String?
        var simulated = false
    }

    struct RideDelta: Codable {
        var app = "CorckieApp"
        var schemaVersion: Int
        var build: String
        var createdAt: Int64
        var rideCount = 1
        var ride: RideRecord
        var samples: [RideSampleRecord]
        var stops: [StopRecord]
        var gaps: [GapRecord]
        var chunks: [RawChunkRecord]
    }

    struct LatestJSON: Codable {
        var app = "CorckieApp"
        var schemaVersion: Int
        var build: String
        var createdAt: Int64
        var rideCount: Int
        var lastFull: String?
        var settings: [String: String]
    }

    /// Writes into `<root>/CorckieApp Backup/`. Used by the real folder and by check u16 (a temporary folder).
    static func perform(db: AppDatabase, root: URL, rideId: String?, fullDue: Bool, nowMs: Int64, offsetMin: Int) throws -> Outcome {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(BackupPlan.folderName, isDirectory: true)
        let ridesDir = dir.appendingPathComponent("rides", isDirectory: true)
        try fm.createDirectory(at: ridesDir, withIntermediateDirectories: true)
        let schema = try db.appliedMigrations().count
        var out = Outcome()

        if fullDue {
            let name = BackupPlan.fullName(atMs: nowMs, utcOffsetMin: offsetMin)
            let tmp = fm.temporaryDirectory.appendingPathComponent("corckie-full-\(UUID().uuidString).sqlite")
            defer { try? fm.removeItem(at: tmp) }
            try db.writeSnapshot(to: tmp)
            let data = try Data(contentsOf: tmp)
            try gzip(data).write(to: dir.appendingPathComponent(name), options: .atomic)
            out.fullName = name
        }

        let q = RideQueries(db)
        if let rideId, let ride = try q.ride(id: rideId), ride.kind != "discarded" {
            let delta = RideDelta(schemaVersion: schema, build: AppInfo.build, createdAt: nowMs, ride: ride,
                                  samples: try q.samples(rideId: rideId), stops: try q.stops(rideId: rideId),
                                  gaps: try q.gaps(rideId: rideId), chunks: try q.chunks(rideId: rideId))
            let name = BackupPlan.rideName(startAtMs: ride.startAt, utcOffsetMin: ride.utcOffsetMin ?? offsetMin, rideId: rideId)
            let json = try JSONEncoder().encode(delta)
            try gzip(json).write(to: ridesDir.appendingPathComponent(name), options: .atomic)
            out.rideFile = name
            out.simulated = ride.isSimulated
        }

        let settings: [String: String] = try db.writer.read { db in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, json FROM setting") {
                let key: String = row["key"]
                let json: String = row["json"]
                map[key] = json
            }
            return map
        }
        let rideCount = try db.rowCounts()["ride"] ?? 0
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let newestFull = names.compactMap { BackupPlan.fullDate($0) }.max()
        let latest = LatestJSON(schemaVersion: schema, build: AppInfo.build, createdAt: nowMs, rideCount: rideCount,
                                lastFull: newestFull.map { "full-\($0).corckie" }, settings: settings)
        try JSONEncoder().encode(latest).write(to: dir.appendingPathComponent("latest.json"), options: .atomic)

        // pruning: the last 3 fulls; ride deltas older than the newest full
        for old in BackupPlan.fullsToDelete(names) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        let rideNames = (try? fm.contentsOfDirectory(atPath: ridesDir.path)) ?? []
        for old in BackupPlan.ridesToDelete(rideNames, newestFullDate: newestFull) {
            try? fm.removeItem(at: ridesDir.appendingPathComponent(old))
        }
        return out
    }

    /// gzip frame around Apple's raw deflate
    static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        return Data(GzipFrame.wrap(deflated: [UInt8](deflated), original: [UInt8](data)))
    }

    /// The inverse of `gzip` (used by check u16 to read a backup back): checks the header, the CRC and the size.
    static func gunzip(_ file: Data) throws -> Data {
        let bytes = [UInt8](file)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw CocoaError(.fileReadCorruptFile) }
        let body = Data(bytes[10..<(bytes.count - 8)])
        let original = try (body as NSData).decompressed(using: .zlib) as Data
        let crcBytes = Array(bytes[(bytes.count - 8)..<(bytes.count - 4)])
        var crc: UInt32 = 0
        for (i, b) in crcBytes.enumerated() { crc |= UInt32(b) << UInt32(i * 8) }
        guard crc == GzipFrame.crc32([UInt8](original)) else { throw CocoaError(.fileReadCorruptFile) }
        return original
    }
}
