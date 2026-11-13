import CorckieCore
import Foundation
import GRDB

/// B81 (hotfix 103.081126.02): Settings → Export log. One zip with everything the app logs, at most 5 MB (owner, 9 Nov):
/// - database/: every table (all rides incl. discarded, places, routes, charges, settings, error log, messages sent, odometer gaps,
///   insights, predictions, weather, …); ride samples and raw packets per ride in rides/
/// - report/: the Report a problem files (checks, error log, Bluetooth events, packets, device, sensors, …) and the c8 ride files
/// - diary/: the 30-day diary; missed-ride-reports/: the saved "Ride not recorded" reports
/// Above 5 MB the oldest detail goes first (per ride its raw packets, then its samples; c8 files by date). Summaries, tables, logs,
/// the diary and the reports always stay. README.txt says what was left out.
enum LogExporter {
    struct Result {
        var url: URL
        var bytes: Int
        var leftOut: String?
    }

    /// N5-1: `level` .trimmed / .noGPS make the privacy-safe export (no names, no locations near the rider's places; no diary or report files).
    static func make(level: PrivacyLevel = .full) throws -> Result {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let name = "CorckieApp-log-\(AppInfo.version)-\(f.string(from: Date()))"
        let folder = fm.temporaryDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: folder)
        for sub in ["database", "rides", "report", "diary", "missed-ride-reports"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        Diary.shared.note("report", "Export log started")
        var detail: [ExportCap.DetailFile] = []

        // 1. the database
        if let db = AppModel.shared.database {
            let enc = JSONEncoder()
            try db.writer.read { d in
                let placeZones = level == .full ? [] : PrivacyTrim.zonesFromPlaces(try BundleTable.read(d, table: "place"))
                let tables = try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
                for t in tables where t != "ride_sample" && t != "raw_chunk" {
                    let raw = try BundleTable.read(d, table: t)
                    let table = level == .full ? raw : PrivacyTrim.blank(raw)
                    try enc.encode(table).write(to: folder.appendingPathComponent("database/\(t).json"))
                }
                let rides = try Row.fetchAll(d, sql: "SELECT id, startAt FROM ride ORDER BY startAt")
                for r in rides {
                    let id: String = r["id"]
                    let at: Int64 = r["startAt"] ?? 0
                    for (table, kind) in [("raw_chunk", ExportCap.DetailFile.Kind.raw), ("ride_sample", .samples)] {
                        var rows = try BundleTable.read(d, table: table, where: "rideId = ?", arguments: [id])
                        if table == "ride_sample" { rows = PrivacyTrim.trimSamples(rows, level: level, placeZones: placeZones) }
                        guard !rows.rows.isEmpty else { continue }
                        let file = "rides/\(at)-\(id)-\(kind == .raw ? "raw" : "samples").json"
                        let data = try enc.encode(rows)
                        try data.write(to: folder.appendingPathComponent(file))
                        detail.append(ExportCap.DetailFile(name: file, atMs: at, kind: kind, bytes: data.count))
                    }
                }
            }
        }

        // 2. the Report a problem files and the c8 ride files
        if level == .full { try Exporter.writeReportFiles(into: folder.appendingPathComponent("report")) }
        for file in (level == .full ? C8Recorder.shared.exportFiles() : []) {
            let target = "report/\(file.lastPathComponent)"
            try? fm.copyItem(at: file, to: folder.appendingPathComponent(target))
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let at = Int64(((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000)
            detail.append(ExportCap.DetailFile(name: target, atMs: at, kind: .raw, bytes: (attrs?[.size] as? Int) ?? 0))
        }

        // 3. the diary and the saved reports
        for file in (level == .full ? Diary.shared.files() : []) { try? fm.copyItem(at: file, to: folder.appendingPathComponent("diary/\(file.lastPathComponent)")) }
        for file in (level == .full ? MissedRideReports.files() : []) { try? fm.copyItem(at: file, to: folder.appendingPathComponent("missed-ride-reports/\(file.lastPathComponent)")) }

        // 4. zip, dropping the oldest detail while over 5 MB
        var dropped: [ExportCap.DetailFile] = []
        var zip = try writeReadmeAndZip(folder, dropped: dropped)
        var tries = 0
        while zip.bytes > ExportCap.capBytes, tries < 8 {
            tries += 1
            let left = detail.filter { d in !dropped.contains(where: { $0.name == d.name }) }
            let raw = folderBytes(folder)
            var more = ExportCap.toDrop(left, zipBytes: zip.bytes, rawBytes: raw)
            if more.isEmpty, let first = ExportCap.dropOrder(left).first { more = [first] }
            if more.isEmpty { break }
            for m in more { try? fm.removeItem(at: folder.appendingPathComponent(m.name)) }
            dropped += more
            zip = try writeReadmeAndZip(folder, dropped: dropped)
        }
        let leftOut = leftOutLine(dropped)
        Diary.shared.note("report", "Export log made: \(zip.bytes / 1024) KB" + (leftOut.map { " · \($0)" } ?? ""))
        return Result(url: zip.url, bytes: zip.bytes, leftOut: leftOut)
    }

    private static func leftOutLine(_ dropped: [ExportCap.DetailFile]) -> String? {
        guard let newest = dropped.map(\.atMs).max() else { return nil }
        let day = Date(timeIntervalSince1970: Double(newest) / 1000).formatted(date: .abbreviated, time: .omitted)
        return "Detail up to \(day) not included (5 MB limit)"
    }

    private static func writeReadmeAndZip(_ folder: URL, dropped: [ExportCap.DetailFile]) throws -> (url: URL, bytes: Int) {
        var text = """
        CorckieApp Export log · \(AppInfo.versionLine) · \(Date().formatted(date: .abbreviated, time: .standard))
        database/  every table (rides incl. discarded, places, routes, charges, settings, error log, messages, odometer gaps, …)
        rides/     per ride: raw scooter packets and samples
        report/    the Report a problem files and the c8 ride files
        diary/     the 30-day diary: app, Bluetooth, ride detection, phone state, logs, voice, notifications
        missed-ride-reports/  saved "Ride not recorded" reports (30 days)
        Phone now: \(Diary.phoneState())

        """
        if let line = leftOutLine(dropped) {
            text += "\n\(line). Left out (oldest first):\n" + dropped.map(\.name).joined(separator: "\n") + "\n"
        } else {
            text += "\nNothing left out.\n"
        }
        try text.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let url = try Exporter.zipFolder(folder)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return (url, bytes)
    }

    private static func folderBytes(_ folder: URL) -> Int {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let u = e?.nextObject() as? URL { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
