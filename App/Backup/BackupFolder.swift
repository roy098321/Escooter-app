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
