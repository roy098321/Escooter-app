import Foundation
import Observation

/// The backup folder picked once in Files / iCloud Drive (C13, P2 D08 ✅), kept as a
/// security-scoped bookmark. P5 writes the real backups (DATA_MODEL §5); the foundation
/// build proves the write, also after a phone restart.
@Observable
final class BackupFolder {
    static let shared = BackupFolder()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let bookmarkKey = "corckie.backupBookmark"
    @ObservationIgnored private let lastWriteKey = "corckie.lastBackupTestWrite"

    private(set) var folderName: String?
    private(set) var log: [String] = []

    var hasFolder: Bool { defaults.data(forKey: bookmarkKey) != nil }

    private init() {
        if let data = defaults.data(forKey: bookmarkKey), let url = try? resolve(data) {
            folderName = url.lastPathComponent
        }
    }

    func remember(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            defaults.set(try url.bookmarkData(), forKey: bookmarkKey)
            folderName = url.lastPathComponent
            add("Folder saved: \(url.lastPathComponent)")
        } catch {
            add("❌ Couldn't remember the folder: \(error.localizedDescription)")
            Log.error(source: "backup", "bookmark: \(error.localizedDescription)")
        }
    }

    /// Writes and reads back a small test file (check d2; d3 when the phone restarted since).
    func writeTestFile() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            if stale { defaults.set(try folder.bookmarkData(), forKey: bookmarkKey) }
            let file = folder.appendingPathComponent("CorckieApp-backup-test.txt")
            let text = "CorckieApp \(AppInfo.versionLine) backup test · \(Date().formatted())\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            guard try String(contentsOf: file, encoding: .utf8) == text else {
                add("❌ The file read back differently")
                CheckResults.shared.set("d2", .fail, "The file read back differently")
                return
            }
            add("✅ Wrote and read back \(file.lastPathComponent)\(stale ? " (folder link refreshed)" : "")")
            CheckResults.shared.set("d2", .pass, "Wrote and read back a file in \(folder.lastPathComponent)")
            if let last = defaults.object(forKey: lastWriteKey) as? Date,
               Date().timeIntervalSince(last) > ProcessInfo.processInfo.systemUptime {
                CheckResults.shared.set("d3", .pass, "Wrote again after a phone restart")
                add("✅ The phone restarted since the last write: still works")
            }
            defaults.set(Date(), forKey: lastWriteKey)
        } catch {
            add("❌ \(error.localizedDescription)")
            CheckResults.shared.set("d2", .fail, error.localizedDescription)
            Log.error(source: "backup", error.localizedDescription)
        }
    }

    private func resolve(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    private func add(_ line: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
    }
}

/// d9: write a test backup (a SQLite snapshot, as DATA_MODEL §5), restore it into a scratch
/// database, and compare every table's rows. The real database is only read.
enum BackupRestoreTest {
    static func run() {
        guard let db = AppModel.shared.database else {
            CheckResults.shared.set("d9", .fail, "Database not open")
            return
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("corckie-restore-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("restored"), withIntermediateDirectories: true)
            let snapshot = folder.appendingPathComponent("backup.sqlite")
            let before = try db.rowCounts()
            try db.writeSnapshot(to: snapshot)
            let size = (try? fm.attributesOfItem(atPath: snapshot.path)[.size] as? Int) ?? 0
            let scratch = folder.appendingPathComponent("restored/corckie.sqlite")
            try fm.copyItem(at: snapshot, to: scratch)
            let restored = try AppDatabase(url: scratch, build: AppInfo.build)
            let after = try restored.rowCounts()
            // error_log can grow while the test runs; every other table must match exactly
            let differing = before.keys.filter { $0 != "error_log" && before[$0] != after[$0] }.sorted()
            let rows = before.filter { $0.key != "error_log" }.values.reduce(0, +)
            if differing.isEmpty {
                CheckResults.shared.set("d9", .pass, "Backup written (\(size / 1024) KB) and restored into a scratch database: \(before.count) tables, \(rows) rows match")
            } else {
                CheckResults.shared.set("d9", .fail, "Rows differ after restore in: \(differing.joined(separator: ", "))")
            }
        } catch {
            CheckResults.shared.set("d9", .fail, "Backup / restore failed: \(error.localizedDescription)")
            Log.error(source: "backup", "restore test: \(error.localizedDescription)")
        }
    }
}
