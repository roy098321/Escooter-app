import CorckieCore
import Foundation

/// u28 (M3-02): the charge log on made-up rides in a temporary database (the real rows are never touched): a charge found
/// from a rested % jump, small rises ignored, simulated rides never mixed in, a charge row saved, equivalent cycles, battery
/// health gated at 5 cycles + 20 rides, and the sag rule only using the next start when no charge is in between.
/// The line ends with this phone's charge log and cycles (read only).
enum ChargeLogCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        let hour: Int64 = 3_600_000
        let t0: Int64 = 1_790_000_000_000
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u28", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let store = RideQueries(temp)
            func add(_ id: String, hours: Int64, from: Double?, to: Double?, km: Double = 15, live: Int? = nil, sim: Bool = false) throws {
                var r = RideRecord(id: id, startAt: t0 + hours * hour)
                r.endAt = r.startAt + 1_800_000
                r.status = "ended"
                r.isSimulated = sim
                r.energyWhRaw = 336
                r.startRestPct = from
                r.endRestPct = to
                if let from, let to { r.usedPct = from - to; r.usedPctMethod = "rested" }
                r.distanceM = km * 1000
                try store.save(r)
                if let live {
                    var s = RideSampleRecord(rideId: id, t: 1_000_000)
                    s.batteryPct = live
                    try store.insert(samples: [s])
                }
            }
            // a ends at 40%, b starts at 86% (+46% charged), c starts 1 point above b's end (not a charge), a simulated ride in between
            try add("a", hours: 0, from: 85, to: 40)
            try add("s", hours: 5, from: 99, to: 50, sim: true)
            try add("b", hours: 20, from: 86, to: 60)
            try add("c", hours: 30, from: 61, to: 40)
            let out = try CalibrationUpdater.update(temp, nowMs: t0)
            let rows = try ChargeQueries(temp).all()
            let foundOk = out.charges.count == 1 && rows.count == 1 && rows.first?.afterRideId == "a" && rows.first?.beforeRideId == "b"
                && rows.first?.fromPct == 40 && rows.first?.toPct == 86
            let ignoredOk = !rows.contains { $0.beforeRideId == "c" || $0.beforeRideId == "s" }

            // sag stand-in replaced: with no charge in between the next start is the end, with a charge it is not
            try add("d", hours: 40, from: 90, to: nil, live: 50)
            try add("e", hours: 50, from: 56, to: nil)
            let sag = try CalibrationUpdater.update(temp, nowMs: t0)
            let sagOk = sag.verdicts["d"] != .rejected(.noRestedEnd) && sag.verdicts["d"] != .rejected(.chargedBetween) && !sag.charges.contains { $0.afterRideId == "d" }
            try add("f", hours: 60, from: 40, to: nil, live: 20)
            try add("g", hours: 120, from: 95, to: 80)
            let chg = try CalibrationUpdater.update(temp, nowMs: t0)
            let chgOk = chg.verdicts["f"] == .rejected(.noRestedEnd) && chg.charges.contains { $0.afterRideId == "f" }

            // cycles and health on the made-up numbers
            let ridesNow = try CalibrationQueries(temp).inputs().map(CalibrationUpdater.chargeRide(from:))
            let cycles = ChargeCycles.equivalent(charges: chg.charges, rides: ridesNow)
            let cyclesOk = cycles > 0.9 && cycles < 4
            let gateOk: Bool
            if case .gathering = BatteryHealth.evaluate(rides: ridesNow, cycles: cycles) { gateOk = true } else { gateOk = false }
            let day: Int64 = 86_400_000
            let year = (0..<24).map { i in
                ChargeRide(id: "h\(i)", startAt: t0 + Int64(i) * 12 * day, kind: "ride", startRestPct: 90, endRestPct: 50, usedPct: 40,
                           distanceM: (i < 12 ? 32_000 : 28_800))
            }
            let healthOk: Bool
            if case let .health(pct, _, _) = BatteryHealth.evaluate(rides: year, cycles: 10) { healthOk = abs(pct - 90) < 0.01 } else { healthOk = false }

            let ok = foundOk && ignoredOk && sagOk && chgOk && cyclesOk && gateOk && healthOk
            let now = realLine(real)
            results.set("u28", ok ? .pass : .fail,
                        "charge found from a rested jump (+46%, window saved) \(foundOk ? "ok" : "wrong") · small rise / simulated ride ignored \(ignoredOk ? "ok" : "wrong") · "
                        + "sag rule only without a charge \(sagOk && chgOk ? "ok" : "wrong") · cycles \(String(format: "%.1f", cycles)) \(cyclesOk ? "ok" : "wrong") · "
                        + "health gated at 5 cycles + 20 rides, 90% on a 10% drop \(gateOk && healthOk ? "ok" : "wrong") · this phone: \(now)")
        } catch {
            results.set("u28", .fail, "Charge log check failed: \(error.localizedDescription)")
        }
    }

    private static func realLine(_ real: AppDatabase?) -> String {
        guard let real, let rows = try? ChargeQueries(real).all(), let inputs = try? CalibrationQueries(real).inputs() else { return "no data" }
        let rides = inputs.map(CalibrationUpdater.chargeRide(from:))
        let charges = ChargeDetector.detect(rides).filter { !$0.isSimulated }
        let cycles = ChargeCycles.equivalent(charges: charges, rides: rides)
        return "\(rows.count) charge\(rows.count == 1 ? "" : "s") logged, \(String(format: "%.1f", cycles)) cycles"
    }
}
