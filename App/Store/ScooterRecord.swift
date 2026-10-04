import Foundation
import GRDB

/// The paired scooter's row in `scooter` (DATA_MODEL §2): fingerprint kept across launches
/// (B03: the export showed "Scooter: ?" after a relaunch).
struct ScooterRecord: Equatable {
    var id: String
    var name: String?
    var chip: String?
    var firmware: String?
    var software: String?
    var firstSeenAt: Int64?

    var fingerprint: String { "\(chip ?? "?") · fw \(firmware ?? "?") · sw \(software ?? "?")" }

    /// Inserts or updates the fingerprint; firstSeenAt is kept from the first time.
    static func save(id: String, name: String?, chip: String?, firmware: String?, software: String?,
                     in db: AppDatabase) throws {
        guard !db.isReadOnly else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO scooter (id, name, peripheralId, firstSeenAt, chip, firmware, software)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, chip = excluded.chip,
                  firmware = excluded.firmware, software = excluded.software
                """, arguments: [id, name, id, now, chip, firmware, software])
        }
    }

    static func latest(in db: AppDatabase) -> ScooterRecord? {
        try? db.writer.read { d -> ScooterRecord? in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM scooter WHERE forgottenAt IS NULL ORDER BY firstSeenAt DESC LIMIT 1") else {
                return nil
            }
            let id: String = row["id"]
            let name: String? = row["name"]
            let chip: String? = row["chip"]
            let firmware: String? = row["firmware"]
            let software: String? = row["software"]
            let first: Int64? = row["firstSeenAt"]
            return ScooterRecord(id: id, name: name, chip: chip, firmware: firmware, software: software, firstSeenAt: first)
        }
    }
}
