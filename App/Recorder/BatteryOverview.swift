import CorckieCore
import Foundation

// M3-03 / M3-04: everything the Battery page shows, read from the stored rides and charges. Honest numbers; the 10% decision
// margin is only in `range.decisionRangeKm`. Compiled into AppTests with App/Store (the Recorder uses the calibration).

struct BatteryOverview {
    var calibration: BatteryCalibration
    /// Newest first
    var charges: [ChargeRecord]
    /// M31 equivalent charge cycles
    var cycles: Double
    var health: BatteryHealth.State
    var currentPct: Double?
    var connected: Bool
    /// M25 (nil: no ride yet or no battery % known)
    var range: RealRange?
    var reservePct: Double
    /// M37 from the current % (only while connected, the scooter is off while it charges)
    var chargeHours: Double?
    /// M37 latest-ride tile: the last ride's rested end % and when it would be full if plugged in as the ride ended;
    /// hidden once a charge was found after that ride
    var sinceLastRide: (endPct: Double, fullAtMs: Int64)?

    static func load(_ db: AppDatabase, currentPct: Double?, connected: Bool) -> BatteryOverview {
        let cal = CalibrationUpdater.current(db)
        let rows = (try? CalibrationQueries(db).inputs()) ?? []
        let chargeRides = rows.map(CalibrationUpdater.chargeRide(from:))
        let detected = ChargeDetector.detect(chargeRides).filter { !$0.isSimulated }
        let cycles = ChargeCycles.equivalent(charges: detected, rides: chargeRides)
        let health = BatteryHealth.evaluate(rides: chargeRides, cycles: cycles)
        let stored = (try? ChargeQueries(db).all()) ?? []
        let ranOut: String? = try? RideQueries(db).setting(key: "t80.batteryRanOut")
        let reserve = RealRangeCalc.reservePct(ranOutJson: ranOut)
        let rangeRides = rows.map { r in
            RangeRide(startAt: r.startAt, kind: r.kind, isSimulated: r.isSimulated, distanceM: r.distanceM, usedPct: r.usedPct,
                      energyWhRaw: r.energyWhRaw, gapScooterS: Double(r.longestGapMs ?? 0) / 1000,
                      endPct: r.endRestPct ?? r.lastLivePct.map(Double.init))
        }
        let range = RealRangeCalc.compute(currentPct: currentPct, rides: rangeRides, calibration: cal, reservePct: reserve)
        let hours = connected ? currentPct.map { ChargeTime.hoursToFull(fromPct: $0, packAh: cal.packAh) } : nil
        var since: (endPct: Double, fullAtMs: Int64)?
        if !connected,
           let last = rows.first(where: { !$0.isSimulated && $0.kind == "ride" && $0.endAt != nil }),
           let endAt = last.endAt, let endPct = last.endRestPct,
           !stored.contains(where: { $0.afterRideId == last.id }) {
            since = (endPct, ChargeTime.fullAt(endAtMs: endAt, endPct: endPct, packAh: cal.packAh))
        }
        return BatteryOverview(calibration: cal, charges: stored, cycles: cycles, health: health, currentPct: currentPct,
                               connected: connected, range: range, reservePct: reserve, chargeHours: hours, sinceLastRide: since)
    }
}
