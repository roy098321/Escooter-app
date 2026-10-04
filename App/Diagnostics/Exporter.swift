import Foundation

/// ONE export for Claude (TESTING §6): results + error log + Bluetooth events + raw packets
/// (+ device and database info), zipped into a single file for the share sheet.
enum Exporter {
    static func makeExport() throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let name = "corckie-checks-\(AppInfo.version)-\(AppInfo.build)-\(stamp)"
        let folder = fm.temporaryDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = AppModel.shared
        try CheckResults.shared.report().write(to: folder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        try CheckResults.shared.notesReport().write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try ErrorLog.shared.lines().joined(separator: "\n")
            .write(to: folder.appendingPathComponent("error-log.txt"), atomically: true, encoding: .utf8)
        try model.scooter.events.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("bluetooth-events.txt"), atomically: true, encoding: .utf8)
        try PacketLog.shared.csv().write(to: folder.appendingPathComponent("scooter-packets.csv"), atomically: true, encoding: .utf8)
        try deviceText().write(to: folder.appendingPathComponent("device.txt"), atomically: true, encoding: .utf8)
        try OutsideProbes.shared.report().write(to: folder.appendingPathComponent("outside-data.txt"), atomically: true, encoding: .utf8)
        try PhoneSensors.shared.report().write(to: folder.appendingPathComponent("sensors.txt"), atomically: true, encoding: .utf8)

        let zip = try zipFolder(folder)
        CheckResults.shared.set("g1", .pass, "Export made: \(zip.lastPathComponent)")
        return zip
    }

    private static func deviceText() -> String {
        let model = AppModel.shared
        var savedScooter = "none yet"
        if let db = model.database, let record = ScooterRecord.latest(in: db) {
            let first = Date(timeIntervalSince1970: Double(record.firstSeenAt ?? 0) / 1000)
            savedScooter = "\(record.fingerprint) · first seen \(first.formatted())"
        }
        var lines: [String] = [
            "App: \(AppInfo.displayName) \(AppInfo.versionLine) · \(AppInfo.bundleID)",
            "Scooter (this session): \(model.scooter.deviceInfo.fingerprint)",
            "Scooter (saved): \(savedScooter)",
            "Untouched (denied) services seen: \(model.scooter.deniedSeen.joined(separator: ", "))",
            "Packets this session: \(model.scooter.packets) (\(model.scooter.packetsInBackground) in the background, \(model.scooter.unknownPackets) unknown)"
        ]
        if let db = model.database {
            lines.append("Database: migrations \((try? db.appliedMigrations())?.joined(separator: ", ") ?? "?") · read-only \(db.isReadOnly)")
            if let meta = db.meta {
                lines.append("Install \(meta.installId) · first build \(meta.createdBuild ?? "?") · launches \(meta.launchCount)")
            }
            if let counts = try? db.rowCounts() {
                lines.append("Rows: " + counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", "))
            }
        } else {
            lines.append("Database: not open · \(model.databaseError ?? "")")
        }
        lines.append("MetricKit: \(CrashCatcher.shared.metricKitReports.joined(separator: " | "))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The system zips a folder when it is read "for uploading" (no zip library needed).
    private static func zipFolder(_ folder: URL) throws -> URL {
        var coordinatorError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zipped in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipped, to: target)
                result = .success(target)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }
}
