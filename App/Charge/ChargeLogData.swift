import CorckieCore
import Foundation

/// F-27: what the charge log chart draws, from the stored rides (readings), the charges found between rides, and the timer's own log.
struct ChargeLogData {
    var readings: [ChargeReading]
    var rows: [ChargeRow]
    var nowMs: Int64
    /// N6-2: when each real ride of the last 8 days started (for "12 rides")
    var rideStarts: [Int64] = []

    static func load(_ db: AppDatabase, charges: [ChargeRecord], entries: [ChargeLogEntry], nowMs: Int64) -> ChargeLogData {
        var readings: [ChargeReading] = []
        var rideStarts: [Int64] = []
        // N6-2: the battery % logged during the last 8 days of rides, as the smoothed level (D-PR-09): a ride is its real drain
        let since = nowMs - 8 * 86_400_000
        let whPerPct = CalibrationUpdater.current(db).whPerPct
        let rideQ = RideQueries(db)
        for r in ((try? CalibrationQueries(db).inputs()) ?? []) where !r.isSimulated && r.kind == "ride" {
            if let s = r.startRestPct { readings.append(ChargeReading(ms: r.startAt, pct: s)) }
            if let e = r.endAt {
                if let p = r.endRestPct ?? r.startRestPct.flatMap({ s in r.usedPct.map { s - $0 } }) { readings.append(ChargeReading(ms: e, pct: p)) }
            }
            guard r.startAt >= since else { continue }
            rideStarts.append(r.startAt)
            let points = ((try? rideQ.samples(rideId: r.id)) ?? []).map {
                SeriesPoint(t: Double(r.startAt + $0.t) / 1000, speedKmh: $0.speedMps.map { $0 * 3.6 }, batteryPct: $0.batteryPct, powerW: $0.powerW)
            }
            readings += BatteryLog.smoothedRide(points, whPerPct: whPerPct)
        }
        for e in entries {
            readings.append(ChargeReading(ms: e.startMs, pct: e.startPct))                              // the start was a real reading
            if e.measured { readings.append(ChargeReading(ms: e.endMs, pct: e.endPct)) }               // an unplugged end is only the line's ≈
        }
        let l = LastSeen.load()
        if let ms = l.ms, let p = l.pct { readings.append(ChargeReading(ms: ms, pct: Double(p))) }
        let detected: [DetectedCharge] = charges.compactMap { c in
            guard let f = c.fromPct, let t = c.toPct, let s = c.windowStartAt, let e = c.windowEndAt else { return nil }
            return DetectedCharge(id: c.id, afterRideId: c.afterRideId ?? "", beforeRideId: c.beforeRideId ?? "", fromPct: f, toPct: t, windowStartAt: s, windowEndAt: e,
                                  startedByShutdownFlag: c.startedByShutdownFlag, inferredWhileAway: c.inferredWhileAway, isSimulated: false)
        }
        return ChargeLogData(readings: readings.sorted { $0.ms < $1.ms }, rows: ChargeLogChart.rows(entries: entries, detected: detected), nowMs: nowMs,
                             rideStarts: rideStarts)
    }
}
