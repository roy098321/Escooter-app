import CorckieCore
import Foundation
import GRDB

/// M5-07: raw data retention. Raw scooter packets (`raw_chunk`) older than the setting (90 days by default; 1 year; forever) are deleted.
/// The energy chunks stay forever (tiny, they keep old rides recalculable) and so does every ride row, sample, stop and summary:
/// only the raw packet stream goes.
enum RetentionService {
    static func current(_ db: AppDatabase) -> RawRetention {
        RawRetention(stored: (try? RideQueries(db).setting(key: RawRetention.settingKey)) ?? nil)
    }

    static func set(_ db: AppDatabase, _ value: RawRetention, nowMs: Int64 = FactorUpdater.nowMs()) {
        try? RideQueries(db).setSetting(key: RawRetention.settingKey, json: value.storageValue)
        _ = try? run(db, nowMs: nowMs)
    }

    /// Deletes what the setting no longer keeps; returns how many chunks went.
    @discardableResult
    static func run(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs()) throws -> Int {
        guard !db.isReadOnly, let cutoff = current(db).cutoffMs(nowMs: nowMs) else { return 0 }
        let kept = Array(RawRetention.keptKinds)
        let marks = kept.map { _ in "?" }.joined(separator: ", ")
        var args: [DatabaseValueConvertible?] = [cutoff]
        args.append(contentsOf: kept)
        return try db.writer.write { d in
            try d.execute(sql: "DELETE FROM raw_chunk WHERE endAt < ? AND kind NOT IN (\(marks))", arguments: StatementArguments(args))
            return d.changesCount
        }
    }

    /// Chunks and bytes of raw data on this phone, for the Settings line
    static func usage(_ db: AppDatabase) -> (chunks: Int, bytes: Int) {
        let row = try? db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(blob)), 0) AS b FROM raw_chunk")
        }
        guard let row else { return (0, 0) }
        let n: Int = row["n"]
        let b: Int = row["b"]
        return (n, b)
    }
}
