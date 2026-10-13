import Foundation
import GRDB

/// F-01: the `price_history` table (migration v4): fuel price (ILS per litre) and electricity rate (ILS per kWh) as value + "valid from"
/// day. A new price is a new row; past rows are never changed by a later price. Plain rows only (App/Store is compiled into AppTests alone).
struct PriceRow: Equatable {
    var kind: String
    /// yyyy-MM-dd
    var validFrom: String
    var value: Double
    var source: String?
    var unverified: Bool
}

struct PriceHistoryQueries {
    static let fuel = "fuel"
    static let electricity = "electricity"

    /// September's official price, 95 octane self-service incl. VAT (Ministry of Energy announcement of 30 Aug 2026)
    static let septemberSource = "https://www.gov.il/BlobFolder/news/fuel-september-2026/he/fuel-september-2026.pdf"
    static let defaultSeptember = PriceRow(kind: fuel, validFrom: "2026-09-01", value: 8.25, source: septemberSource, unverified: false)
    static let defaultOctober = PriceRow(kind: fuel, validFrom: "2026-10-01", value: 8.27, source: "manual", unverified: false)

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func rows(kind: String) throws -> [PriceRow] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, validFrom, value, source, unverified FROM price_history WHERE kind = ? ORDER BY validFrom", arguments: [kind]).map { r in
                let unverified: Int = r["unverified"]
                return PriceRow(kind: r["kind"], validFrom: r["validFrom"], value: r["value"], source: r["source"], unverified: unverified != 0)
            }
        }
    }

    /// Adds a price valid from a day (a row with the same day is replaced: that is how a typo is fixed).
    func set(_ row: PriceRow) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO price_history (kind, validFrom, value, source, unverified) VALUES (?, ?, ?, ?, ?)",
                           arguments: [row.kind, row.validFrom, row.value, row.source, row.unverified ? 1 : 0])
        }
    }

    func remove(kind: String, validFrom: String) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM price_history WHERE kind = ? AND validFrom = ?", arguments: [kind, validFrom])
        }
    }

    /// First launch after v4: the fuel prices of September and October 2026 when missing (never replaces a row the owner edited).
    func ensureDefaults() {
        guard !database.isReadOnly else { return }
        try? database.writer.write { db in
            for row in [Self.defaultSeptember, Self.defaultOctober] {
                try db.execute(sql: "INSERT OR IGNORE INTO price_history (kind, validFrom, value, source, unverified) VALUES (?, ?, ?, ?, ?)",
                               arguments: [row.kind, row.validFrom, row.value, row.source, row.unverified ? 1 : 0])
            }
        }
    }

    /// The electricity rate from a day on. With no rows yet, the rate that applied until now (default 0.64) is kept for the past first.
    func setElectricity(_ value: Double, from day: String, currentDefault: Double) throws {
        if try rows(kind: Self.electricity).isEmpty {
            try set(PriceRow(kind: Self.electricity, validFrom: "2000-01-01", value: currentDefault, source: "setting", unverified: false))
        }
        try set(PriceRow(kind: Self.electricity, validFrom: day, value: value, source: "manual", unverified: false))
    }
}
