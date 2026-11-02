import CorckieCore
import Foundation

/// Hotfix 03 proof: every V09 line said in a ride, with the numbers behind it (setting "v09.said", the newest 300 lines). The ride
/// summary compares them with what really happened (under More). Main thread only.
enum V09LineLog {
    static let key = "v09.said"
    static let keep = 300

    static func all(_ db: AppDatabase) -> [V09SaidLine] {
        guard let json = try? RideQueries(db).setting(key: key), let data = json.data(using: .utf8),
              let lines = try? JSONDecoder().decode([V09SaidLine].self, from: data) else { return [] }
        return lines
    }

    static func add(_ line: V09SaidLine, db: AppDatabase?) {
        guard let db, !db.isReadOnly else { return }
        var lines = all(db)
        lines.append(line)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        guard let data = try? JSONEncoder().encode(lines), let json = String(data: data, encoding: .utf8) else { return }
        try? RideQueries(db).setSetting(key: key, json: json)
    }

    /// The lines said between two moments (epoch s)
    static func lines(_ db: AppDatabase, fromS: Double, toS: Double) -> [V09SaidLine] {
        all(db).filter { $0.numbers.t >= fromS && $0.numbers.t <= toS }
    }
}
