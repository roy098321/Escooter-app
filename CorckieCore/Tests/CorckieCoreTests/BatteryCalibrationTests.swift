import XCTest
@testable import CorckieCore

/// M3-01: battery calibration from rides (CALC_SPEC M8 S1, T41, T42). The three real rides are given as their numbers only
/// (energy and rested %; EXPERIMENTS_LOG "Ride data"), no coordinates.
final class BatteryCalibrationTests: XCTestCase {
    static let day: Int64 = 86_400_000
    let t0: Int64 = 20_000 * 86_400_000

    private func ride(_ id: String, day: Int, wh: Double?, from: Double?, to: Double?, kind: String = "ride", sim: Bool = false,
                      gapS: Double = 0, live: Double? = nil, next: Double? = nil) -> CalibrationRide {
        let start = t0 + Int64(day) * Self.day
        return CalibrationRide(id: id, startAt: start, endAt: start + 1_800_000, kind: kind, isSimulated: sim, energyWhRaw: wh,
                               startRestPct: from, endRestPct: to, lastLivePct: live, nextStartRestPct: next, longestGapS: gapS)
    }

    /// 29 Sep 322 Wh 64 → 23%, 3 Oct 501 Wh 91 → 31%, 5 Oct 366 Wh 99 → 56%
    private var realRides: [CalibrationRide] {
        [ride("29sep", day: 0, wh: 322, from: 64, to: 23), ride("3oct", day: 4, wh: 501, from: 91, to: 31), ride("5oct", day: 6, wh: 366, from: 99, to: 56)]
    }

    func test_prior_from16Ah() {
        let p = BatteryCalibration.prior()
        XCTAssertEqual(p.packWh, 768, accuracy: 1e-9)
        XCTAssertEqual(p.whPerPct, 8.1408, accuracy: 1e-9)
        XCTAssertEqual(p.status, .prior)
        XCTAssertEqual(p.confidence, 0)
        // the logged rides: 785–850 Wh per 100%
        XCTAssertTrue((785.0...850.0).contains(p.usableWh))
    }

    func test_eachRealRide_hasItsWhPerPct() {
        XCTAssertEqual(BatteryCalibrator.evaluate(realRides[0]), .used(whPerPct: 322.0 / 41, dropPct: 41, endFromNextStart: false))
        XCTAssertEqual(BatteryCalibrator.evaluate(realRides[1]), .used(whPerPct: 501.0 / 60, dropPct: 60, endFromNextStart: false))
        XCTAssertEqual(BatteryCalibrator.evaluate(realRides[2]), .used(whPerPct: 366.0 / 43, dropPct: 43, endFromNextStart: false))
    }

    func test_threeRealRides_learningBlendedWithPrior() {
        let (cal, verdicts) = BatteryCalibrator.calibrate(realRides)
        XCTAssertEqual(cal.status, .learning)
        XCTAssertEqual(cal.ridesUsed, 3)
        XCTAssertEqual(cal.confidence, 0.6, accuracy: 1e-9)
        XCTAssertEqual(cal.measuredWhPerPct ?? 0, 8.35, accuracy: 1e-9)          // median of 7.85, 8.35, 8.51
        XCTAssertEqual(cal.whPerPct, (8.1408 * 2 + 8.35 * 3) / 5, accuracy: 1e-9)  // 8.27 Wh per 1%
        XCTAssertEqual(cal.usableWh, 826.6, accuracy: 0.1)
        XCTAssertEqual(cal.factor, cal.whPerPct / 7.68, accuracy: 1e-9)
        XCTAssertTrue(verdicts.values.allSatisfy(\.isUsed))
        XCTAssertFalse(cal.checkSuggested)
        // still learning: the ride rows keep the rested drop
        XCTAssertEqual(BatteryCalibrator.usedForRide(realRides[2], cal).method, "rested")
        XCTAssertEqual(BatteryCalibrator.usedForRide(realRides[2], cal).usedPct, 43)
    }

    func test_convergence_settlesAfterFiveRides() {
        let truth = 8.6
        let noise = [0.97, 1.03, 0.99, 1.02, 1.0, 0.98, 1.01, 1.02, 0.99, 1.0, 1.03, 0.97]
        var rides: [CalibrationRide] = []
        var confidences: [Double] = []
        for (i, f) in noise.enumerated() {
            let drop = 30.0 + Double(i % 4) * 5
            rides.append(ride("r\(i)", day: i, wh: truth * f * drop, from: 90, to: 90 - drop))
            let cal = BatteryCalibrator.calibrate(rides).calibration
            confidences.append(cal.confidence)
            XCTAssertEqual(cal.status, i + 1 >= 5 ? .calibrated : .learning, "ride \(i + 1)")
            if i + 1 >= 5 { XCTAssertEqual(cal.whPerPct, truth, accuracy: truth * 0.02, "ride \(i + 1)") }
        }
        XCTAssertEqual(confidences.prefix(6), [0.2, 0.4, 0.6, 0.8, 1, 1])
        // only the newest 10 count
        XCTAssertEqual(BatteryCalibrator.calibrate(rides).calibration.ridesUsed, 10)
    }

    func test_outliers_rejectedWithoutMovingTheValue() {
        var rides = (0..<5).map { ride("g\($0)", day: $0, wh: 8.4 * 40, from: 80, to: 40) }
        rides.append(ride("low", day: 6, wh: 5.0 * 40, from: 80, to: 40))   // 40% off: an outlier
        rides.append(ride("bad", day: 7, wh: 2.5 * 40, from: 80, to: 40))   // below half the prior: impossible
        let (cal, verdicts) = BatteryCalibrator.calibrate(rides)
        XCTAssertEqual(verdicts["low"], .rejected(.outlier))
        XCTAssertEqual(verdicts["bad"], .rejected(.implausible))
        XCTAssertEqual(cal.whPerPct, 8.4, accuracy: 1e-9)
        XCTAssertEqual(cal.ridesUsed, 5)
    }

    func test_shortHopsSmallDropsGapsAndPhoneModeAreLeftOut() {
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("h", day: 0, wh: 20, from: 80, to: 78, kind: "shortHop")), .rejected(.notARide))
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("s", day: 0, wh: 70, from: 80, to: 72)), .rejected(.smallDrop))
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("g", day: 0, wh: 300, from: 80, to: 40, gapS: 90)), .rejected(.gap))
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("p", day: 0, wh: 0, from: 80, to: 40)), .rejected(.noEnergy))
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("n", day: 0, wh: nil, from: 80, to: 40)), .rejected(.noEnergy))
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("u", day: 0, wh: 300, from: nil, to: 40)), .rejected(.noRestedStart))
        // a 60 s gap is still fine (T41: no gap over 1 min)
        XCTAssertTrue(BatteryCalibrator.evaluate(ride("g60", day: 0, wh: 330, from: 80, to: 40, gapS: 60)).isUsed)
    }

    func test_simulatedRides_neverCalibrate() {
        let sims = (0..<6).map { ride("sim\($0)", day: $0, wh: 12 * 40, from: 80, to: 40, sim: true) }
        let (cal, verdicts) = BatteryCalibrator.calibrate(sims + [realRides[0]])
        XCTAssertEqual(cal.ridesUsed, 1)
        XCTAssertEqual(cal.status, .learning)
        XCTAssertEqual(verdicts["sim0"], .rejected(.simulated))
        XCTAssertEqual(BatteryCalibrator.calibrate(sims).calibration, BatteryCalibration.prior())
        // and a simulated ride row never gets an energy-based used %
        let five = BatteryCalibrator.calibrate((0..<5).map { ride("g\($0)", day: $0, wh: 8.4 * 40, from: 80, to: 40) }).calibration
        XCTAssertEqual(BatteryCalibrator.usedForRide(sims[0], five).method, "rested")
    }

    func test_sagAware_endFromTheNextConnection() {
        // switched off before resting: live 50% at the end, the next start rested 56% (recovered from sag) → used
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("a", day: 0, wh: 8.4 * 40, from: 96, to: nil, live: 50, next: 56)),
                       .used(whPerPct: 8.4, dropPct: 40, endFromNextStart: true))
        // 30 points higher next time: a charge in between, not sag
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("b", day: 0, wh: 300, from: 96, to: nil, live: 50, next: 80)), .rejected(.chargedBetween))
        // nothing to go on: the live % is never used (it reads low under load)
        XCTAssertEqual(BatteryCalibrator.evaluate(ride("c", day: 0, wh: 300, from: 96, to: nil, live: 50)), .rejected(.noRestedEnd))
    }

    func test_linkNextStarts_unlessAChargeWasFoundBetween() {
        let a = ride("a", day: 0, wh: 300, from: 90, to: nil, live: 50)
        var b = ride("b", day: 0, wh: 100, from: 55, to: 40)
        b.startAt = a.startAt + 30 * 3_600_000   // 30 h later: the old 24 h rule would have dropped it
        let linked = BatteryCalibrator.linkNextStarts([b, a])
        XCTAssertEqual(linked.map(\.id), ["b", "a"])
        XCTAssertEqual(linked[1].nextStartRestPct, 55)
        // M30 found a charge after "a": nothing is linked
        XCTAssertNil(BatteryCalibrator.linkNextStarts([a, b], chargedAfter: ["a"]).first { $0.id == "a" }?.nextStartRestPct)
    }

    func test_calibrated_ridesUseEnergy_andTheMarginStaysOut() {
        let rides = (0..<5).map { ride("g\($0)", day: $0, wh: 8.4 * 40, from: 80, to: 40) }
        let cal = BatteryCalibrator.calibrate(rides).calibration
        XCTAssertTrue(cal.isCalibrated)
        let used = BatteryCalibrator.usedForRide(ride("x", day: 9, wh: 168, from: 70, to: 52), cal)
        XCTAssertEqual(used.method, "calibrated")
        XCTAssertEqual(used.usedPct ?? 0, 20, accuracy: 1e-9)            // honest: no 10% in it
        XCTAssertEqual(used.energyWhCal ?? 0, 168 / cal.factor, accuracy: 1e-9)
        XCTAssertEqual(SafetyMargin.forDecision(used.usedPct ?? 0), 22, accuracy: 1e-9)
        // a ride with a long gap keeps the rested drop (no S4 gap filling yet)
        XCTAssertEqual(BatteryCalibrator.usedForRide(ride("y", day: 9, wh: 100, from: 70, to: 52, gapS: 120), cal).method, "rested")
        XCTAssertEqual(cal.wh(forPct: 50), 420, accuracy: 1e-9)
        XCTAssertEqual(cal.pct(forWh: 84), 10, accuracy: 1e-9)
        XCTAssertEqual(cal.pctPerKm(whPerKm: 25.2), 3, accuracy: 1e-9)
    }

    func test_confirmation_threeRidesInARowOffSuggestACheck() {
        var rides = (0..<5).map { ride("g\($0)", day: $0, wh: 8.4 * 40, from: 80, to: 40) }
        XCTAssertFalse(BatteryCalibrator.calibrate(rides).calibration.checkSuggested)
        rides += (5..<7).map { ride("o\($0)", day: $0, wh: 11 * 40, from: 80, to: 40) }
        XCTAssertFalse(BatteryCalibrator.calibrate(rides).calibration.checkSuggested)   // two in a row only
        rides.append(ride("o7", day: 7, wh: 11 * 40, from: 80, to: 40))
        let cal = BatteryCalibrator.calibrate(rides).calibration
        XCTAssertTrue(cal.checkSuggested)
        XCTAssertEqual(cal.whPerPct, 8.4, accuracy: 1e-9)
    }
}
