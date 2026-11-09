import CorckieCore
import Foundation
import GRDB

/// B81 (hotfix 103.081126.02): "Ride not recorded" reports. Saved by the rider (Settings → Ride not recorded) or by the app when the
/// odometer shows riding that was not recorded. Kept 30 days, go with Export log. Read-only toward the scooter (nothing is sent).
enum MissedRideReports {
    struct Report: Codable {
        var createdAt: Int64
        var build: String
        var auto: Bool
        var when: String
        var roughStartAt: Int64?
        var windowFrom: Int64
        var windowTo: Int64
        var cause: String?
        var phoneNow: String
        var odometerNowKm: Double?
        var lastRideEndOdoKm: Double?
        var missedKm: Double?
        var rides: [RideLine]
        var diary: [String]
    }

    struct RideLine: Codable {
        var id: String
        var startAt: Int64
        var kind: String
        var status: String?
        var distanceM: Double?
        var endReason: String?
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("missed-ride-reports", isDirectory: true)
    }

    static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Saves a report; returns the one-line cause when the app can tell (nil = "Saved. It goes with your next export.")
    @discardableResult
    static func save(when: MissedRideWhen?, roughStartMs: Int64?, auto: Bool, window explicit: ClosedRange<Int64>? = nil) -> String? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let window = explicit ?? MissedRideWhen.window(when ?? .justNow, nowMs: now, roughStartMs: roughStartMs)
        let rides = rideLines(in: window)
        let diary = Diary.shared.lines(in: window)
        let cause = MissedRideGuess.cause(lines: diary, rides: rides.map { MissedRideRow(startAt: $0.startAt, kind: $0.kind, distanceM: $0.distanceM) },
                                          window: window, locationAlways: Diary.shared.locationAlways,
                                          utcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
        let odoNow = AppModel.shared.scooter.connected ? AppModel.shared.live.frame?.odometerKm : nil
        let lastOdo = lastRideEndOdo()
        let missed = (odoNow != nil && lastOdo != nil) ? max(0, odoNow! - lastOdo!) : nil
        let report = Report(createdAt: now, build: AppInfo.versionLine, auto: auto, when: when?.rawValue ?? "odometer gap",
                            roughStartAt: roughStartMs, windowFrom: window.lowerBound, windowTo: window.upperBound, cause: cause,
                            phoneNow: Diary.phoneState(), odometerNowKm: odoNow, lastRideEndOdoKm: lastOdo, missedKm: missed,
                            rides: rides, diary: diary.map(\.encoded))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(report).write(to: folder.appendingPathComponent("report-\(now).json"), options: .atomic)
        } catch {
            Log.error(source: "missed-ride", "Report not saved: \(error.localizedDescription)")
        }
        Diary.shared.note("report", "Ride not recorded report saved (\(auto ? "automatic, odometer gap" : when?.label ?? "")) · cause: \(cause ?? "unknown")")
        return cause
    }

    /// Automatic report when the odometer shows riding that was not recorded: the window runs from the last ride's end to now
    static func savedForGap(km: Double) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let from = lastRideEndMs() ?? now - 86_400_000
        save(when: nil, roughStartMs: nil, auto: true, window: from...max(from, now))
        Log.info(source: "missed-ride", "Automatic report for \(String(format: "%.1f", km)) km not recorded")
    }

    private static func rideLines(in window: ClosedRange<Int64>) -> [RideLine] {
        guard let db = AppModel.shared.database else { return [] }
        return (try? db.writer.read { d in
            try Row.fetchAll(d, sql: "SELECT id, startAt, kind, status, distanceM, endReason FROM ride WHERE startAt BETWEEN ? AND ? AND isSimulated = 0 ORDER BY startAt",
                             arguments: [window.lowerBound, window.upperBound]).map { r in
                RideLine(id: r["id"], startAt: r["startAt"], kind: r["kind"] ?? "", status: r["status"], distanceM: r["distanceM"], endReason: r["endReason"])
            }
        }) ?? []
    }

    private static func lastRideEndOdo() -> Double? {
        guard let db = AppModel.shared.database else { return nil }
        return try? db.writer.read { d in
            try Double.fetchOne(d, sql: "SELECT odoEndKm FROM ride WHERE odoEndKm IS NOT NULL AND isSimulated = 0 ORDER BY startAt DESC LIMIT 1")
        }
    }

    private static func lastRideEndMs() -> Int64? {
        guard let db = AppModel.shared.database else { return nil }
        return try? db.writer.read { d in
            try Int64.fetchOne(d, sql: "SELECT endAt FROM ride WHERE endAt IS NOT NULL AND isSimulated = 0 ORDER BY startAt DESC LIMIT 1")
        }
    }

    /// Reports older than 30 days go (LogRetention); returns how many
    static func clean(nowMs: Int64) -> Int {
        let cut = LogRetention.cutoffMs(nowMs: nowMs, days: LogRetention.reportDays)
        var n = 0
        for f in files() {
            let ms = Int64(f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "report-", with: "")) ?? 0
            if ms < cut { try? FileManager.default.removeItem(at: f); n += 1 }
        }
        return n
    }
}
