import CorckieCore
import Foundation

/// u27 (M3-01): battery calibration on the three real rides (their numbers only) and on made-up rides in a temporary
/// database (the real rows are never touched): Wh per 1%, learning → calibrated after 5 rides, outliers, short hops,
/// gaps and simulated rides left out, the `calibration` row and the rides' used % re-run. The line ends with the real
/// calibration as it stands (read only) for bt1.
enum CalibrationCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        // the three real rides: 29 Sep 322 Wh 64 → 23%, 3 Oct 501 Wh 91 → 31%, 5 Oct 366 Wh 99 → 56%
        let day: Int64 = 86_400_000
        let t0: Int64 = 1_790_000_000_000
        let realRides = [(322.0, 64.0, 23.0), (501, 91, 31), (366, 99, 56)].enumerated().map { i, r in
            CalibrationRide(id: "r\(i)", startAt: t0 + Int64(i) * day, energyWhRaw: r.0, startRestPct: r.1, endRestPct: r.2)
        }
        let three = BatteryCalibrator.calibrate(realRides).calibration
        let threeOk = three.status == .learning && three.ridesUsed == 3 && abs((three.measuredWhPerPct ?? 0) - 8.35) < 0.01
            && abs(three.whPerPct - 8.266) < 0.01

        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u27", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let store = RideQueries(temp)
            func add(_ id: String, _ i: Int, wh: Double, from: Double, to: Double, kind: String = "ride", sim: Bool = false) throws {
                var r = RideRecord(id: id, startAt: t0 + Int64(i) * day)
                r.endAt = r.startAt + 1_800_000
                r.status = "ended"
                r.kind = kind
                r.isSimulated = sim
                r.energyWhRaw = wh
                r.startRestPct = from
                r.endRestPct = to
                r.usedPct = max(0, from - to)
                r.usedPctMethod = "rested"
                r.distanceM = 15_000
                try store.save(r)
            }
            for i in 0..<4 { try add("g\(i)", i, wh: 8.4 * 40, from: 85, to: 45) }
            try add("hop", 4, wh: 15, from: 45, to: 44, kind: "shortHop")
            try add("sim", 5, wh: 12 * 40, from: 85, to: 45, sim: true)
            try add("odd", 6, wh: 5 * 40, from: 85, to: 45)
            let four = try CalibrationUpdater.update(temp, nowMs: t0)
            let fourOk = four.calibration.status == .learning && four.calibration.ridesUsed == 4
                && four.verdicts["hop"] == .rejected(.notARide) && four.verdicts["sim"] == .rejected(.simulated) && four.verdicts["odd"] == .rejected(.outlier)
            let stillRested = try store.ride(id: "g0")?.usedPctMethod == "rested"
            try add("g4", 7, wh: 8.4 * 40, from: 85, to: 45)
            let five = try CalibrationUpdater.update(temp, nowMs: t0 + 7 * day)
            let row = try CalibrationQueries(temp).current()
            let rowOk = row?.status == "active" && row?.ridesUsed == 5 && abs((row?.factor ?? 0) - 8.4 / 7.68) < 1e-6
            let reread = CalibrationUpdater.current(temp)
            let rereadOk = reread.isCalibrated && abs(reread.whPerPct - 8.4) < 1e-6
            let g0 = try store.ride(id: "g0")
            let simRow = try store.ride(id: "sim")
            let rerunOk = g0?.usedPctMethod == "calibrated" && abs((g0?.usedPct ?? 0) - 40) < 1e-6 && simRow?.usedPctMethod == "rested"
            let marginOk = abs(SafetyMargin.forDecision(g0?.usedPct ?? 0) - 44) < 1e-6
            let ok = threeOk && fourOk && stillRested && five.calibration.isCalibrated && rowOk && rereadOk && rerunOk && marginOk
            let now = CalibrationUpdater.current(real)
            results.set("u27", ok ? .pass : .fail,
                        String(format: "3 real rides %.2f Wh per 1%% (measured %.2f, ~%ld Wh usable, learning 3 of 5) ",
                               three.whPerPct, three.measuredWhPerPct ?? 0, Int(three.usableWh.rounded())) + (threeOk ? "ok" : "wrong") + " · "
                        + "short hop, simulated and outlier left out \(fourOk ? "ok" : "wrong") · rested % until 5 rides \(stillRested ? "ok" : "wrong") · "
                        + "calibrated at 5, row saved \(rowOk && rereadOk ? "ok" : "wrong") · rides re-run from energy \(rerunOk ? "ok" : "wrong") · "
                        + "margin only in decisions \(marginOk ? "ok" : "wrong") · this phone: \(now.summaryText)")
        } catch {
            results.set("u27", .fail, "Calibration check failed: \(error.localizedDescription)")
        }
    }
}
