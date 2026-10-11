import CorckieCore
import CorckieSim
import Foundation
import GRDB

// Import ride logs (Settings → Data and backup). Log files recorded before 1.0 (a 0.4 c8 set, or an nRF Connect log with optional
// Sensor Logger files) are replayed through the REAL Recorder, the same code that records on the street, into the real database as a
// normal ride (isSimulated = 0, real timestamps, the ride's own UTC offset). The Recorder's ride close then runs calibration, routes,
// factors, choice points, insights and the field kit exactly as for a ridden ride; afterwards the same finish steps as Restore.
// A ride that is already on the phone is found first (RestorePlan, on a dry run in a temporary database) and nothing is added.
// The ride is marked as imported with a setting row `import.ride.<id>` (no schema change).
// Compiled into AppTests too (with App/Store and App/Recorder), so it uses nothing else from the app.

struct RideLogImportReport: Equatable {
    var added = 0
    var skipped = 0
    var failed = 0
    var distanceM = 0.0
    var energyWh = 0.0
    var rideIds: [String] = []
    var notes: [String] = []

    /// "Imported 1 ride · 15.3 km · 366 Wh", or why nothing was added
    var text: String {
        var lines: [String] = []
        if added > 0 {
            var line = "Imported \(added) ride\(added == 1 ? "" : "s") · " + String(format: "%.1f km", distanceM / 1000)
                + " · \(Int(energyWh.rounded())) Wh"
            if skipped > 0 { line += " · \(skipped) already here" }
            lines.append(line)
        } else if skipped > 0 {
            lines.append("Nothing new: \(skipped) ride\(skipped == 1 ? " is" : "s are") already on this phone.")
        } else {
            lines.append("No ride found in these files.")
        }
        if failed > 0 { lines.append("\(failed) log\(failed == 1 ? "" : "s") could not be turned into a ride.") }
        lines += notes
        return lines.joined(separator: "\n")
    }
}

enum RideLogImporter {
    /// The phone's UTC offset (minutes) at an epoch second
    static let deviceOffsetMin: @Sendable (Double) -> Int = { TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: $0)) / 60 }

    static func run(_ db: AppDatabase, files: [ImportFileText], build: String,
                    utcOffsetMinAt: (Double) -> Int = RideLogImporter.deviceOffsetMin) async throws -> RideLogImportReport {
        guard !db.isReadOnly else { throw RestoreError.readOnly }
        let logs = try RideLogImport.build(files: files, utcOffsetMin: utcOffsetMinAt)
        var report = RideLogImportReport()
        let q = RideQueries(db)
        for log in logs {
            report.notes += log.notes
            // 1. dry run in a temporary database: when and how far did this log ride? is that ride already here?
            let incoming = try await dryRun(log, build: build)
            guard !incoming.isEmpty else {
                report.failed += 1
                report.notes.append("\(log.fileNames[0]): no ride in it (the scooter never moved, or the log is too short).")
                continue
            }
            let existing = try db.writer.read { d in
                try Row.fetchAll(d, sql: "SELECT id, startAt, distanceM FROM ride").map {
                    RestoreRide(id: $0["id"], startAt: $0["startAt"], distanceM: $0["distanceM"])
                }
            }
            let plan = RestorePlan.decide(existing: existing, incoming: incoming)
            if !plan.skip.isEmpty {
                report.skipped += incoming.count
                continue
            }
            // 2. the real run: the real Recorder into the real database
            let openBefore = Set(try q.openRides().map(\.id))
            let rec = Recorder(database: db, simulated: false, build: build, stateURL: nil, utcOffsetMin: log.utcOffsetMin)
            await rec.process(log.inputs())
            let closed = await rec.closedRideIds
            let errors = await rec.writeErrors
            for open in try q.openRides() where !openBefore.contains(open.id) { _ = try q.delete(rideId: open.id) }
            if closed.isEmpty {
                report.failed += 1
                report.notes.append("\(log.fileNames[0]): the ride could not be stored" + (errors.first.map { " (\($0))" } ?? "."))
                continue
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            for id in closed {
                guard let ride = try q.ride(id: id) else { continue }
                let info: [String: Any] = ["at": nowMs, "source": log.source, "files": log.fileNames]
                if let data = try? JSONSerialization.data(withJSONObject: info), let json = String(data: data, encoding: .utf8) {
                    try q.setSetting(key: "import.ride.\(id)", json: json)
                }
                report.added += 1
                report.distanceM += ride.distanceM ?? 0
                report.energyWh += ride.energyWhRaw ?? 0
                report.rideIds.append(id)
            }
        }
        if report.added > 0 { RestoreService.finish(db) }
        return report
    }

    /// The log replayed into a temporary database: the rides it makes (start, distance), nothing touches the real database.
    private static func dryRun(_ log: ImportedRideLog, build: String) async throws -> [RestoreRide] {
        let temp = try AppDatabase.openTemporary(build: build)
        defer { temp.discardTemporary() }
        let dry = Recorder(database: temp, simulated: false, build: build, stateURL: nil, utcOffsetMin: log.utcOffsetMin)
        await dry.process(log.inputs())
        let ids = await dry.closedRideIds
        let tq = RideQueries(temp)
        var out: [RestoreRide] = []
        for id in ids {
            if let r = try tq.ride(id: id) { out.append(RestoreRide(id: id, startAt: r.startAt, distanceM: r.distanceM)) }
        }
        return out
    }

    /// Rides that came from an import
    static func importedIds(_ db: AppDatabase) -> Set<String> {
        let keys = (try? db.writer.read { d in try String.fetchAll(d, sql: "SELECT key FROM setting WHERE key LIKE 'import.ride.%'") }) ?? []
        return Set(keys.map { String($0.dropFirst("import.ride.".count)) })
    }
}
