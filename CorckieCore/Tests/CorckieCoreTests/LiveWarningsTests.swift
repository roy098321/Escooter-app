import XCTest
@testable import CorckieCore

/// P6-3 chunk 3: battery 20 / 15 / 10 voice warnings, the km-left blend, F-22 and the motor, merged by the director.
final class LiveWarningsTests: XCTestCase {
    // MARK: words and km

    func test_numbersAsWords() {
        XCTAssertEqual(SpokenNumber.words(20), "twenty")
        XCTAssertEqual(SpokenNumber.words(15), "fifteen")
        XCTAssertEqual(SpokenNumber.words(6), "six")
        XCTAssertEqual(SpokenNumber.words(42), "forty two")
        XCTAssertEqual(SpokenNumber.words(120), "120")
    }

    func test_blendWeightsThisRideUpTo70PercentAfter5Km() {
        // under 1 km: the recent rides only
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 4, rideKm: 0.5, recentPctPerKm: 2)!, 2, accuracy: 1e-9)
        // 2.5 km: weight = 0.5 x 0.7 = 0.35
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 4, rideKm: 2.5, recentPctPerKm: 2)!, 0.35 * 4 + 0.65 * 2, accuracy: 1e-9)
        // 5 km and more: 70 % this ride, 30 % recent
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 4, rideKm: 5, recentPctPerKm: 2)!, 0.7 * 4 + 0.3 * 2, accuracy: 1e-9)
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 4, rideKm: 12, recentPctPerKm: 2)!, 3.4, accuracy: 1e-9)
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: nil, rideKm: 8, recentPctPerKm: 2)!, 2, accuracy: 1e-9)
        XCTAssertEqual(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 3, rideKm: 8, recentPctPerKm: nil)!, 3, accuracy: 1e-9)
        XCTAssertNil(BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: nil, rideKm: 8, recentPctPerKm: nil))
    }

    func test_kmLeftRoundsDownWithNoMargin() {
        XCTAssertEqual(BatteryRangeSpeech.kmLeft(pct: 20, reservePct: 5, pctPerKm: 2.2), 6, "15 / 2.2 = 6.8 -> 6")
        XCTAssertEqual(BatteryRangeSpeech.kmLeft(pct: 20, reservePct: 5, pctPerKm: 2.5), 6, "exactly 6.0 stays 6")
        XCTAssertEqual(BatteryRangeSpeech.kmLeft(pct: 10, reservePct: 5, pctPerKm: 2), 2)
        XCTAssertEqual(BatteryRangeSpeech.kmLeft(pct: 4, reservePct: 5, pctPerKm: 2), 0)
        XCTAssertNil(BatteryRangeSpeech.kmLeft(pct: 20, reservePct: 5, pctPerKm: nil))
    }

    func test_theSpokenLine() {
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 20, kmLeft: 6), "Battery at twenty percent, about six kilometres left.")
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 15, kmLeft: 4), "Battery at fifteen percent, about four kilometres left.")
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 10, kmLeft: 1), "Battery at ten percent, less than two kilometres left.")
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 10, kmLeft: 0), "Battery at ten percent, less than two kilometres left.")
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 10, kmLeft: 2), "Battery at ten percent, about two kilometres left.")
        XCTAssertEqual(BatteryRangeSpeech.line(percent: 10, kmLeft: nil), "Battery at ten percent.")
    }

    // MARK: battery levels

    func test_levelsFireInOrderAfter30SecondsEachOnce() {
        var b = BatteryWarningTracker()
        var spoken: [Int] = []
        var t = 0.0
        for pct in stride(from: 24.0, through: 8.0, by: -0.5) {      // 10 s per half percent
            for _ in 0..<10 {
                if let p = b.update(pct: pct, at: t) { spoken.append(p) }
                t += 1
            }
        }
        XCTAssertEqual(spoken, [20, 15, 10])
    }

    func test_aBouncingPercentNeverFiresBefore30SecondsHeld() {
        var b = BatteryWarningTracker()
        XCTAssertNil(b.update(pct: 22, at: 0))
        for k in 0..<20 {   // 20 <-> 21 every 10 s: never held 30 s
            XCTAssertNil(b.update(pct: k % 2 == 0 ? 20 : 21, at: Double(1 + k * 10)))
        }
        XCTAssertNil(b.update(pct: 20, at: 300))
        XCTAssertNil(b.update(pct: 20, at: 320))
        XCTAssertEqual(b.update(pct: 19, at: 331), 20, "held since 300 -> fires at 330+")
        XCTAssertNil(b.update(pct: 19, at: 400), "once per ride")
        XCTAssertNil(b.update(pct: 21, at: 500))
        XCTAssertNil(b.update(pct: 20, at: 600))
        XCTAssertNil(b.update(pct: 20, at: 700), "20 is done even after it climbed back")
    }

    func test_aRideStartingBelow20AnnouncesItsLevelOnceThenGoesDown() {
        var b = BatteryWarningTracker()
        XCTAssertEqual(b.update(pct: 17, at: 0), 17, "announced at once at the start")
        XCTAssertNil(b.update(pct: 17, at: 40))
        XCTAssertNil(b.update(pct: 16, at: 80), "20 is not repeated")
        var t = 100.0
        var fired: Int?
        for _ in 0..<40 { if let p = b.update(pct: 14.5, at: t) { fired = p }; t += 1 }
        XCTAssertEqual(fired, 15)
        var low: Int?
        for _ in 0..<40 { if let p = b.update(pct: 9, at: t) { low = p }; t += 1 }
        XCTAssertEqual(low, 10)
    }

    func test_aRideStartingAbove20SaysNothingAtTheStart() {
        var b = BatteryWarningTracker()
        XCTAssertNil(b.update(pct: 80, at: 0))
        XCTAssertNil(b.update(pct: nil, at: 1))
    }

    func test_aJumpPast15Fires15Only() {
        var b = BatteryWarningTracker()
        XCTAssertNil(b.update(pct: 22, at: 0))
        var spoken: [Int] = []
        for k in 0..<80 { if let p = b.update(pct: 14, at: Double(1 + k)) { spoken.append(p) } }
        XCTAssertEqual(spoken, [15], "the 20 level is skipped, not announced late")
    }

    // MARK: motor

    func test_motorHotOncePerHeatAndAgainAfterCoolingBelow() {
        var m = MotorHotTracker()
        XCTAssertFalse(m.update(tempC: 80))
        XCTAssertTrue(m.update(tempC: 90))
        XCTAssertFalse(m.update(tempC: 95))
        XCTAssertFalse(m.update(tempC: 91))
        XCTAssertFalse(m.update(tempC: 89))
        XCTAssertTrue(m.update(tempC: 90), "cooled below the level and hot again")
        XCTAssertFalse(m.update(tempC: nil))
    }

    // MARK: F-22

    private func input(along: Double = 4, route: Double = 8, ride: Double = 4, start: Double = 40, pct: Double = 30, usual: Double = 2) -> DestinationInput {
        DestinationInput(name: "Work", routeKm: route, alongKm: along, rideKm: ride, startPct: start, pct: pct, usualPctPerKm: usual)
    }

    func test_inDoubtNeedsEvidenceEightPercentOverAndTheReserve() {
        // 4 km done at 2.5 %/km, 4 km to go: 30 - 4 x 2.5 x 1.1 = 19 -> not in doubt
        XCTAssertFalse(DestinationRules.inDoubt(input()))
        // 4 km done at 5.5 %/km, 4 km to go: 18 - 4 x 5.5 x 1.1 = -6.2 -> in doubt
        XCTAssertTrue(DestinationRules.inDoubt(input(start: 40, pct: 18)))
        // the same projection but only 1 km ridden of 8 (12.5 %): too early
        XCTAssertFalse(DestinationRules.inDoubt(input(along: 1, ride: 1, start: 24, pct: 18, usual: 2)))
        // 2 km of 6 km (33 %) is enough evidence
        XCTAssertTrue(DestinationRules.inDoubt(input(along: 2, route: 6, ride: 2, start: 22, pct: 10, usual: 2)))
        // this ride about 4 % above usual: below the 8 % rule, never spoken
        XCTAssertFalse(DestinationRules.inDoubt(input(along: 6, route: 8, ride: 6, start: 22, pct: 8.3, usual: 2.2)))
        // 8 % above usual and the margin projection under the reserve
        XCTAssertTrue(DestinationRules.inDoubt(input(along: 6, route: 8, ride: 6, start: 25, pct: 8, usual: 2.5)))
    }

    func test_verdictWordsArriveWithOrShort() {
        // 2 km to go at 2.7 %/km from 11 %: arrives with 5.6 -> "arrive with six percent"
        let a = input(along: 6, route: 8, ride: 6, start: 27.2, pct: 11, usual: 2.4)
        XCTAssertEqual(DestinationRules.verdict(a), .arrive(pct: 6))
        XCTAssertEqual(DestinationRules.line(name: "Work", verdict: .arrive(pct: 3)), "Work: arrive with three percent.")
        XCTAssertEqual(DestinationRules.line(name: "Work", verdict: .short(km: 2)), "Work: two kilometres short.")
        XCTAssertEqual(DestinationRules.line(name: "Work", verdict: .short(km: 1)), "Work: one kilometre short.")
        // 4 km to go at 5 %/km with 10 % left: can ride 2 km, 2 km short
        let s = input(along: 4, route: 8, ride: 4, start: 30, pct: 10, usual: 2)
        XCTAssertEqual(DestinationRules.verdict(s), .short(km: 2))
    }

    func test_speaksOnlyAfter60SecondsAndOnce() {
        var d = DestinationTracker()
        let bad = input(start: 40, pct: 18)
        XCTAssertNil(d.update(bad, at: 0))
        XCTAssertNil(d.update(bad, at: 59))
        XCTAssertNotNil(d.update(bad, at: 61))
        XCTAssertNil(d.update(bad, at: 200), "once")
        XCTAssertNil(d.update(bad, at: 400))
    }

    func test_aRecoveryResetsTheSixtySeconds() {
        var d = DestinationTracker()
        let bad = input(start: 40, pct: 18)
        _ = d.update(bad, at: 0)
        XCTAssertNil(d.update(input(), at: 40), "not in doubt any more")
        XCTAssertNil(d.update(bad, at: 50))
        XCTAssertNil(d.update(bad, at: 100), "only 50 s since it came back")
        XCTAssertNotNil(d.update(bad, at: 111))
    }

    func test_againOnlyIfClearlyWorse() {
        var d = DestinationTracker()
        // arrives with ~5 %: below the reserve with the margin -> "arrive with"
        let marginal = input(along: 6, route: 8, ride: 6, start: 25, pct: 8, usual: 2.5)
        guard case .arrive? = DestinationRules.verdict(marginal) else { return XCTFail("expected arrive") }
        _ = d.update(marginal, at: 0)
        XCTAssertNotNil(d.update(marginal, at: 61))
        XCTAssertNil(d.update(marginal, at: 200))
        let worse = input(along: 6, route: 8, ride: 6, start: 25, pct: 3, usual: 2.5)
        guard case .short? = DestinationRules.verdict(worse) else { return XCTFail("expected short") }
        _ = d.update(worse, at: 300)
        XCTAssertNotNil(d.update(worse, at: 361), "from arrive-with to short")
        XCTAssertNil(d.update(worse, at: 500))
    }

    func test_preRideWarningOnlyBelowNeedPlusMarginAndReserve() {
        XCTAssertEqual(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 40, batteryPct: 45), "Work needs about 40%, you have 45%")
        XCTAssertNil(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 40, batteryPct: 60))
        XCTAssertNil(DestinationRules.preRideWarning(name: "Work", usualNeedPct: nil, batteryPct: 10))
        XCTAssertNil(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 20, batteryPct: nil))
        XCTAssertNotNil(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 20, batteryPct: 26), "20 x 1.1 + 5 = 27")
    }

    func test_usualPctPerKmIsTheMedianOfTheRoutesRides() {
        let rides = [RouteRideStats(rideId: "a", startAt: 1, distanceM: 4000, usedPct: 8),
                     RouteRideStats(rideId: "b", startAt: 2, distanceM: 4000, usedPct: 10),
                     RouteRideStats(rideId: "c", startAt: 3, distanceM: 4000, usedPct: 12),
                     RouteRideStats(rideId: "d", startAt: 4, distanceM: 4000, usedPct: 40, excluded: true)]
        XCTAssertEqual(DestinationRules.usualPctPerKm(rides: rides)!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(DestinationRules.usualKm(rides: rides)!, 4, accuracy: 1e-9)
    }

    // MARK: director

    private func ride(_ d: inout LiveVoiceDirector, from t0: Double, seconds: Int, pct: Double, km: Double = 5, temp: Double? = nil,
                      route: LiveVoiceInput.RouteLive? = nil, recent: Double? = 2.5) -> [LiveUtterance] {
        var out: [LiveUtterance] = []
        for s in 0..<seconds {
            out += d.update(LiveVoiceInput(t: t0 + Double(s), pct: pct, tempC: temp, rideKm: km, recentPctPerKm: recent, route: route))
        }
        return out
    }

    func test_directorSpeaksTheBatteryLineWithKmLeft() {
        var d = LiveVoiceDirector()
        d.beginRide()
        _ = ride(&d, from: 0, seconds: 5, pct: 30, km: 0)
        let out = ride(&d, from: 100, seconds: 40, pct: 20, km: 3)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.ping, .battery)
        XCTAssertEqual(out.first?.taps, 2)
        // ride: 10 % in 3 km = 3.33 %/km, weight 0.6 x 0.7 = 0.42 -> blend 0.42 x 3.33 + 0.58 x 2.5 = 2.85; 15 / 2.85 = 5.26 -> five
        XCTAssertEqual(out.first?.text, "Battery at twenty percent, about five kilometres left.")
    }

    func test_motorHotIsItsOwnUtterance() {
        var d = LiveVoiceDirector()
        let out = ride(&d, from: 0, seconds: 3, pct: 60, temp: 91)
        XCTAssertEqual(out.map { $0.text }, ["Motor hot."])
        XCTAssertEqual(out.first?.ping, .motor)
    }

    func test_aBatteryAndADestinationWarningWithin20SecondsAreOneUtterance() {
        var d = LiveVoiceDirector()
        let route = LiveVoiceInput.RouteLive(name: "Work", routeKm: 8, alongKm: 4, usualPctPerKm: 2)
        _ = d.update(LiveVoiceInput(t: 0, pct: 40, tempC: nil, rideKm: 0, recentPctPerKm: 2.5, route: route))
        // pct 22 -> 18 over the next minute: both the 20 hold (30 s) and the destination hold (60 s) are running
        var out: [LiveUtterance] = []
        for s in 1...120 {
            let pct = s < 15 ? 22.0 : 18.0
            out += d.update(LiveVoiceInput(t: Double(s), pct: pct, tempC: nil, rideKm: 4, recentPctPerKm: 2.5, route: route))
        }
        XCTAssertEqual(out.count, 1, "one merged utterance, not two")
        XCTAssertEqual(out.first?.alerts.count, 2)
        XCTAssertTrue(out.first?.text.contains("Battery at twenty percent") == true && out.first?.text.contains("Work:") == true)
        XCTAssertEqual(out.first?.ping, .battery)
        XCTAssertEqual(out.first?.taps, 3)
    }

    func test_aDestinationWarningAloneUsesThreePings() {
        var d = LiveVoiceDirector()
        let route = LiveVoiceInput.RouteLive(name: "Work", routeKm: 8, alongKm: 4, usualPctPerKm: 2)
        _ = d.update(LiveVoiceInput(t: 0, pct: 60, tempC: nil, rideKm: 0, recentPctPerKm: 2.5, route: route))
        var out: [LiveUtterance] = []
        for s in 1...100 { out += d.update(LiveVoiceInput(t: Double(s), pct: 30, tempC: nil, rideKm: 4, recentPctPerKm: 2.5, route: route)) }
        // 30 % used in 4 km = 7.5 %/km, 4 km to go: short
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.ping, .destination)
        XCTAssertEqual(out.first?.taps, 3)
        XCTAssertEqual(out.first?.text, "Work: one kilometre short.")
    }
}
