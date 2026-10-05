import CorckieCore
import Foundation

// M3-01: battery calibration from rides (CALC_SPEC M8 S1). After every ride close the Recorder calls `update`: the
// calibration is re-computed from all stored rides, saved in the `calibration` row, and the rides' battery used is
// re-run (rested drop while learning, energy-based once calibrated). Route stats, Today and `neededPct` read the
// rides' usedPct, so they follow; the 10% decision margin stays in `SafetyMargin` only.
// Compiled into AppTests with App/Store (the Recorder uses it).

enum CalibrationUpdater {
    /// The calibration in use (hand-off for M3-02 charge log / health, M3-03 range / charge time, M3-04 battery page).
    /// No row yet → the 16 Ah prior.
    static func current(_ database: AppDatabase?) -> BatteryCalibration {
        guard let database, let row = try? CalibrationQueries(database).current() else { return .prior() }
        return calibration(from: row)
    }

    static func calibration(from row: CalibrationRecord) -> BatteryCalibration {
        let packAh = row.packAh ?? T.t42DefaultPackAh
        guard let k = row.factor, k > 0, row.ridesUsed > 0 else { return .prior(packAh: packAh) }
        let whPerPct = k * packAh * T.t42PackVoltage / 100
        let status: BatteryCalibration.Status = row.status == "active" ? .calibrated : .learning
        return BatteryCalibration(packAh: packAh, whPerPct: whPerPct, measuredWhPerPct: nil, ridesUsed: row.ridesUsed, status: status)
    }

    static func ride(from r: CalibrationInputRow) -> CalibrationRide {
        let gapS = r.longestGapMs.map { Double($0) / 1000 } ?? 0
        return CalibrationRide(id: r.id, startAt: r.startAt, endAt: r.endAt, kind: r.kind, isSimulated: r.isSimulated,
                               energyWhRaw: r.energyWhRaw, startRestPct: r.startRestPct, endRestPct: r.endRestPct,
                               lastLivePct: r.lastLivePct.map(Double.init), longestGapS: gapS, distanceM: r.distanceM)
    }

    /// Re-computes, saves the row and re-runs the rides' battery used. Returns the new calibration and its verdicts.
    @discardableResult
    static func update(_ database: AppDatabase, nowMs: Int64, packAh: Double = T.t42DefaultPackAh)
        throws -> (calibration: BatteryCalibration, verdicts: [String: CalibrationVerdict], ridesChanged: Int) {
        let q = CalibrationQueries(database)
        let rows = try q.inputs()
        let rides = BatteryCalibrator.linkNextStarts(rows.map(ride(from:)))
        let (cal, verdicts) = BatteryCalibrator.calibrate(rides, packAh: packAh)

        var record = try q.current() ?? CalibrationRecord(id: CalibrationQueries.mainId, startedAt: nowMs)
        record.status = cal.isCalibrated ? "active" : "learning"
        record.factor = cal.ridesUsed > 0 ? cal.factor : nil
        record.ridesUsed = cal.ridesUsed
        record.packAh = packAh
        try q.save(record)

        // M8 re-run: only rows whose value changes are written
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var changes: [(id: String, usedPct: Double?, method: String?, energyWhCal: Double?)] = []
        for r in rides {
            guard let old = byId[r.id] else { continue }
            let new = BatteryCalibrator.usedForRide(r, cal)
            if !same(old.usedPct, new.usedPct) || old.usedPctMethod != new.method || !same(old.energyWhCal, new.energyWhCal) {
                // a ride without a rested drop and without calibration keeps whatever it had
                if new.usedPct == nil, old.usedPctMethod != "calibrated" { continue }
                changes.append((r.id, new.usedPct, new.method, new.energyWhCal))
            }
        }
        let changed = try q.setUsed(changes)
        return (cal, verdicts, changed)
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 1e-9
        default: return false
        }
    }
}
