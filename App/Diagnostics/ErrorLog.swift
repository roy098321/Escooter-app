import Foundation
import GRDB

/// Errors are never silent (ARCHITECTURE §6.2): `Log.error(source:_:)` → `error_log`
/// (30 days, C28b S3), and the last 500 lines stay in memory for the export even when the
/// database can't be opened.
enum Log {
    static func error(source: String, _ message: String) { ErrorLog.shared.add(level: "error", source: source, message) }
    static func warning(source: String, _ message: String) { ErrorLog.shared.add(level: "warning", source: source, message) }
    static func info(source: String, _ message: String) { ErrorLog.shared.add(level: "info", source: source, message) }
}

final class ErrorLog {
    static let shared = ErrorLog()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let level: String
        let source: String
        let message: String

        var line: String {
            "\(at.formatted(date: .numeric, time: .standard)) [\(level)] \(source): \(message)"
        }
    }

    private(set) var recent: [Entry] = []
    private let queue = DispatchQueue(label: "corckie.errorlog")

    private var database: AppDatabase? { AppModel.shared.database }

    func add(level: String, source: String, _ message: String) {
        let entry = Entry(at: Date(), level: level, source: source, message: message)
        queue.sync {
            recent.append(entry)
            if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        }
        guard let db = database, !db.isReadOnly else { return }
        let ms = Int64(entry.at.timeIntervalSince1970 * 1000)
        try? db.writer.write { d in
            try d.execute(sql: "INSERT INTO error_log (at, level, source, message, build) VALUES (?, ?, ?, ?, ?)",
                          arguments: [ms, level, source, message, AppInfo.versionLine])
        }
    }

    /// Lines from the database (newest last), else from memory.
    func lines(limit: Int = 1000) -> [String] {
        if let db = database,
           let rows = try? db.writer.read({ d in
               try Row.fetchAll(d, sql: "SELECT * FROM (SELECT * FROM error_log ORDER BY id DESC LIMIT ?) ORDER BY id", arguments: [limit])
           }) {
            return rows.map { row in
                let at: Int64 = row["at"]
                let level: String = row["level"]
                let source: String = row["source"]
                let message: String = row["message"]
                let date = Date(timeIntervalSince1970: Double(at) / 1000)
                return "\(date.formatted(date: .numeric, time: .standard)) [\(level)] \(source): \(message)"
            }
        }
        return queue.sync { recent.map(\.line) }
    }

    /// C28b S3: keep 30 days.
    func trim() {
        guard let db = database, !db.isReadOnly else { return }
        let cutoff = Int64((Date().timeIntervalSince1970 - 30 * 86_400) * 1000)
        try? db.writer.write { d in
            try d.execute(sql: "DELETE FROM error_log WHERE at < ?", arguments: [cutoff])
        }
    }
}
