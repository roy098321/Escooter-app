import Foundation
import GRDB

/// The one SQLite database (`corckie.sqlite`, WAL) · DATA_MODEL §1, §4.
///
/// Opening runs the versioning rules before anything else:
/// - V1 numbered migrations (`DatabaseMigrator`), V2 additive only;
/// - V3 a copy `corckie-pre-<build>.sqlite` is written before any migration of existing data,
///   and older copies are removed after the next successful launch;
/// - V4 a failed migration throws: the app shows "Data update failed · Send report";
/// - V6 a database from a newer build opens read-only.
final class AppDatabase {
    enum OpenError: Error, LocalizedError {
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .migrationFailed(let text): return "Data update failed: \(text)"
            }
        }
    }

    struct Meta: Equatable {
        var installId: String
        var createdBuild: String?
        var lastBuild: String?
        var lastMigration: String?
        var createdAt: Int64?
        var launchCount: Int
    }

    let writer: any DatabaseWriter
    let url: URL
    /// V6: opened read-only because the data is newer than this build
    let isReadOnly: Bool
    /// V3: the copy written before this launch's migrations (nil = nothing was migrated)
    let preMigrationCopy: URL?
    /// Migrations applied during this launch
    let migratedNow: [String]
    /// Install / update info after this launch was recorded
    private(set) var meta: Meta?
    /// a9 (T-02): rows per table before and after this launch's migrations (nil = a new database or a read-only one)
    private(set) var updateCounts: (before: [String: Int], after: [String: Int])?

    /// The real database in Application Support.
    static func openShared(build: String) throws -> AppDatabase {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: build)
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(Migration0001.identifier) { db in
            try db.execute(sql: Migration0001.sql)
        }
        migrator.registerMigration(Migration0002.identifier) { db in
            try db.execute(sql: Migration0002.sql)
        }
        migrator.registerMigration(Migration0003.identifier) { db in
            try db.execute(sql: Migration0003.sql)
        }
        // Next: Migration0004 (append only, DATA_MODEL V2)
        return migrator
    }

    init(url: URL, build: String, migrator: DatabaseMigrator = AppDatabase.makeMigrator()) throws {
        self.url = url
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)

        let (applied, superseded, pending) = try pool.read { db -> (Set<String>, Bool, Bool) in
            (try migrator.appliedIdentifiers(db), try migrator.hasBeenSuperseded(db), !(try migrator.hasCompletedMigrations(db)))
        }

        if superseded {
            // V6: never write with an older schema
            try? pool.close()
            var readOnly = Configuration()
            readOnly.readonly = true
            writer = try DatabasePool(path: url.path, configuration: readOnly)
            isReadOnly = true
            preMigrationCopy = nil
            migratedNow = []
            return
        }

        var countsBefore: [String: Int]?
        if !applied.isEmpty { countsBefore = try pool.read { try AppDatabase.allRowCounts($0) } }
        var copy: URL?
        if pending && !applied.isEmpty {
            // V3: back up existing data before touching it
            let target = url.deletingLastPathComponent().appendingPathComponent("corckie-pre-\(build).sqlite")
            try? FileManager.default.removeItem(at: target)
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
            }
            copy = target
        }

        do {
            try migrator.migrate(pool)
        } catch {
            throw OpenError.migrationFailed(String(describing: error))
        }
        let after = try pool.read { db in try migrator.appliedIdentifiers(db) }

        writer = pool
        isReadOnly = false
        preMigrationCopy = copy
        migratedNow = Array(after.subtracting(applied)).sorted()
        if let countsBefore {
            let countsAfter = try pool.read { try AppDatabase.allRowCounts($0) }
            updateCounts = (before: countsBefore, after: countsAfter)
        }
        meta = try recordLaunch(build: build)
        removeOldPreMigrationCopies(keeping: copy)
    }

    /// app_meta: install id, first and last build, launch count (the "update keeps data" check).
    private func recordLaunch(build: String) throws -> Meta {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let lastMigration = migratedNow.last
        return try writer.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM app_meta WHERE id = 1") == nil {
                try db.execute(sql: """
                    INSERT INTO app_meta (id, installId, createdBuild, lastBuild, lastMigration, createdAt, launchCount)
                    VALUES (1, ?, ?, ?, ?, ?, 1)
                    """, arguments: [UUID().uuidString, build, build, lastMigration, now])
            } else {
                try db.execute(sql: """
                    UPDATE app_meta SET lastBuild = ?, launchCount = launchCount + 1,
                      lastMigration = COALESCE(?, lastMigration) WHERE id = 1
                    """, arguments: [build, lastMigration])
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM app_meta WHERE id = 1") else {
                throw OpenError.migrationFailed("app_meta row missing")
            }
            let installId: String = row["installId"]
            let createdBuild: String? = row["createdBuild"]
            let lastBuild: String? = row["lastBuild"]
            let storedMigration: String? = row["lastMigration"]
            let createdAt: Int64? = row["createdAt"]
            let launchCount: Int = row["launchCount"]
            return Meta(installId: installId, createdBuild: createdBuild, lastBuild: lastBuild,
                        lastMigration: storedMigration, createdAt: createdAt, launchCount: launchCount)
        }
    }

    /// V3: earlier copies are kept only until this successful launch.
    private func removeOldPreMigrationCopies(keeping current: URL?) {
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("corckie-pre-") && name != current?.lastPathComponent {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// A consistent copy of the whole database (DATA_MODEL §5 full backup, before gzip).
    func writeSnapshot(to target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
        }
    }

    /// Rows per table, for the migration test and the developer screen.
    func rowCounts() throws -> [String: Int] {
        try writer.read { db in
            var counts: [String: Int] = [:]
            for table in Migration0001.tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }

    /// Rows in every table of the database (all migrations, not only v1), for the update check a9.
    static func allRowCounts(_ db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'")
        for name in names {
            counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
        }
        return counts
    }

    func allRowCounts() throws -> [String: Int] {
        try writer.read { try AppDatabase.allRowCounts($0) }
    }

    /// Applied migrations, oldest first.
    func appliedMigrations() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }
}
