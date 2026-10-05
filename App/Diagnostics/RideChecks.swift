import CorckieCore
import Foundation

/// M1-16: the real-ride checks tick themselves from the rides in the real database (never the simulated ones).
/// Rules live in CorckieCore (`RideCheckRules`); this file only reads the facts and writes the results.
/// Called when a ride closes and by "Run all automatic". Reads only, no coordinates leave this file.
enum RideChecks {
    static func run(database: AppDatabase?) {
        guard let database else { return }
        let store = RideQueries(database)
        guard let rides = try? store.rides() else { return }
        let overLimitMps = 45.0 / 3.6
        let facts: [RideFacts] = rides.filter { !$0.isSimulated && $0.kind == "ride" }.map { ride in
            let samples = (try? store.samples(rideId: ride.id)) ?? []
            let red = Double(samples.filter { ($0.speedMps ?? 0) > overLimitMps }.count) * RideCheckRules.sampleStepS
            return RideFacts(id: ride.id, startAtMs: ride.startAt, utcOffsetMin: ride.utcOffsetMin ?? 0, kind: ride.kind,
                             status: ride.status, endReason: ride.endReason, isSimulated: ride.isSimulated,
                             totalS: ride.totalS ?? 0, distanceM: ride.distanceM, odoStartKm: ride.odoStartKm,
                             odoEndKm: ride.odoEndKm, topSpeedMps: ride.topSpeedMps, sampleCount: samples.count,
                             secondsOverLimit: red, gapScooterS: ride.gapScooterS ?? 0, mergeGroupId: ride.mergeGroupId)
        }
        let results = CheckResults.shared
        for verdict in RideCheckRules.evaluate(facts) {
            switch verdict.result {
            case .pass: results.passOnce(verdict.id, verdict.note)
            case .fail: results.set(verdict.id, .fail, verdict.note)
            case .info: results.set(verdict.id, .info, verdict.note)
            }
        }
        RouteCheck.timing(database: database)
    }

    /// rides.txt in the export: one line per ride, no coordinates and no ride ids.
    static func ridesText(database: AppDatabase?) -> String {
        var out = "Rides · CorckieApp \(AppInfo.versionLine) · \(Date().formatted())\n"
        guard let database, let rides = try? RideQueries(database).rides(includeDiscarded: true) else {
            return out + "\n(database not open)\n"
        }
        out += "\(rides.count) rows (newest first)\n\n"
        for ride in rides {
            let start = Date(timeIntervalSince1970: Double(ride.startAt) / 1000)
            var line = "\(start.formatted(date: .abbreviated, time: .shortened)) · \(ride.kind) · \(ride.status)"
            if let reason = ride.endReason { line += " · end \(reason)" }
            if ride.isSimulated { line += " · SIMULATED" }
            if let total = ride.totalS { line += " · \(Int(total / 60)) min" }
            if let d = ride.distanceM { line += " · \(String(format: "%.2f", d / 1000)) km" }
            if let top = ride.topSpeedMps { line += " · top \(String(format: "%.0f", top * 3.6)) km/h" }
            if let e = ride.energyWhRaw { line += " · \(Int(e)) Wh" }
            if let a = ride.startRestPct, let b = ride.endRestPct { line += " · battery \(Int(a))→\(Int(b))%" }
            if let gap = ride.gapScooterS, gap > 0 { line += " · scooter gaps \(Int(gap)) s" }
            if ride.hasGps == false { line += " · no GPS" }
            if ride.mergeGroupId != nil { line += " · joined (same ride)" }
            out += line + "\n"
        }
        return out
    }
}
