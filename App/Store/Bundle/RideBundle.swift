import Foundation
import GRDB

/// M5-02 / M5-05: a lossless copy of rows as JSON, whatever columns the schema has now or later.
/// Used for the merge undo snapshot, "Export everything" and Restore. A table is `columns` plus `rows`.
enum BundleValue: Codable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .text(s)
        case .blob(let b): self = .blob(b)
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .int(let i): return i.databaseValue
        case .double(let d): return d.databaseValue
        case .text(let s): return s.databaseValue
        case .blob(let b): return b.databaseValue
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .text(s)
        } else {
            let o = try c.decode([String: String].self)
            guard let b64 = o["b64"], let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown value")
            }
            self = .blob(data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .text(let s): try c.encode(s)
        case .blob(let b): try c.encode(["b64": b.base64EncodedString()])
        }
    }

    /// 5 and 5.0 are the same value (JSON does not keep the difference)
    static func == (l: BundleValue, r: BundleValue) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case let (.text(a), .text(b)): return a == b
        case let (.blob(a), .blob(b)): return a == b
        default:
            guard let a = l.number, let b = r.number else { return false }
            return a == b
        }
    }

    var text: String? { if case .text(let s) = self { return s } else { return nil } }
    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}

struct BundleTable: Codable, Equatable {
    var name: String
    var columns: [String]
    var rows: [[BundleValue]]

    /// All rows of `table` that match `where` (nil = all).
    static func read(_ db: Database, table: String, where clause: String? = nil, arguments: StatementArguments = StatementArguments()) throws -> BundleTable {
        let sql = "SELECT * FROM \(table)" + (clause.map { " WHERE " + $0 } ?? "")
        let fetched = try Row.fetchAll(db, sql: sql, arguments: arguments)
        let columns = try db.columns(in: table).map(\.name)
        var rows: [[BundleValue]] = []
        for row in fetched {
            var values: [BundleValue] = []
            for column in columns {
                let v: DatabaseValue = row[column]
                values.append(BundleValue(v))
            }
            rows.append(values)
        }
        return BundleTable(name: table, columns: columns, rows: rows)
    }

    func value(_ row: Int, _ column: String) -> BundleValue? {
        guard row < rows.count, let i = columns.firstIndex(of: column) else { return nil }
        return rows[row][i]
    }

    /// Inserts the rows with `INSERT OR IGNORE` (a row that exists is never overwritten). Only columns the table has now are written;
    /// the `gap` id is left to the database; a `scooterId` that is not on this phone becomes NULL. Returns the rows really added.
    @discardableResult
    func insert(_ db: Database) throws -> Int {
        let existing = Set(try db.columns(in: name).map(\.name))
        var keep: [Int] = []
        for (i, c) in columns.enumerated() where existing.contains(c) && !(name == "gap" && c == "id") { keep.append(i) }
        guard !keep.isEmpty, !rows.isEmpty else { return 0 }
        let names = keep.map { columns[$0] }
        let marks = Array(repeating: "?", count: keep.count).joined(separator: ", ")
        let sql = "INSERT OR IGNORE INTO \(name) (\(names.joined(separator: ", "))) VALUES (\(marks))"
        let scooterIndex = names.firstIndex(of: "scooterId")
        var added = 0
        for row in rows {
            var values = keep.map { row[$0].databaseValue }
            if let si = scooterIndex, let id = row[keep[si]].text {
                let known = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scooter WHERE id = ?", arguments: [id]) ?? 0
                if known == 0 { values[si] = .null }
            }
            let arguments: [DatabaseValueConvertible?] = values.map { $0 as DatabaseValueConvertible? }
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
            added += db.changesCount
        }
        return added
    }
}

/// One ride with everything that belongs to it.
struct RideBundle: Codable, Equatable {
    var rideId: String
    var tables: [BundleTable]

    /// Parent first, so foreign keys hold when the rows go back in
    static let childTables = ["ride_sample", "raw_chunk", "gap", "stop", "ride_option", "ride_climb"]

    static func read(_ db: Database, rideId: String) throws -> RideBundle? {
        let ride = try BundleTable.read(db, table: "ride", where: "id = ?", arguments: [rideId])
        guard !ride.rows.isEmpty else { return nil }
        var tables = [ride]
        for name in childTables {
            tables.append(try BundleTable.read(db, table: name, where: "rideId = ?", arguments: [rideId]))
        }
        return RideBundle(rideId: rideId, tables: tables)
    }

    /// Adds the ride and its rows; false when a ride with this id is already there (nothing is changed).
    @discardableResult
    func insert(_ db: Database) throws -> Bool {
        let present = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ride WHERE id = ?", arguments: [rideId]) ?? 0
        if present > 0 { return false }
        for table in tables { try table.insert(db) }
        return true
    }

    private var rideTable: BundleTable? { tables.first { $0.name == "ride" } }
    var startAt: Int64? { rideTable?.value(0, "startAt")?.int64 }
    var distanceM: Double? { rideTable?.value(0, "distanceM")?.number }
    var sampleCount: Int { tables.first { $0.name == "ride_sample" }?.rows.count ?? 0 }
}
