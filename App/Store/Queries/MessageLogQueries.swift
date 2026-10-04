import Foundation
import GRDB

/// M1-10: `message_log` (DATA_MODEL): every message the app sends or drops, with the reason (CALC_SPEC 9.4).
/// No CorckieCore import: App/Store is compiled into AppTests on its own.
struct MessageLogRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "message_log"

    var id: Int64?
    var type: String?
    /// notification / banner / card
    var channel: String?
    var scheduledFor: Int64?
    /// epoch milliseconds; nil when it was dropped
    var sentAt: Int64?
    var droppedReason: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct MessageLogQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// `at` in epoch milliseconds. A dropped message has a reason and no `sentAt`.
    @discardableResult
    func add(type: String, channel: String, at: Int64, droppedReason: String?) throws -> MessageLogRecord {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        return try database.writer.write { db in
            var row = MessageLogRecord(id: nil, type: type, channel: channel, scheduledFor: at,
                                       sentAt: droppedReason == nil ? at : nil, droppedReason: droppedReason)
            try row.insert(db)
            return row
        }
    }

    func entries(type: String) throws -> [MessageLogRecord] {
        try database.writer.read { db in
            try MessageLogRecord.filter(Column("type") == type).order(Column("id")).fetchAll(db)
        }
    }
}
