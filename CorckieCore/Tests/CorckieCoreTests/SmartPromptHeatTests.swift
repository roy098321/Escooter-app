import XCTest
@testable import CorckieCore

/// M4-05 (smart prompt C26, Loaded tag) and M4-06 (heat cards M38).
final class SmartPromptHeatTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let off = 180

    private func range(median: Double = 9, lo: Double = 8, hi: Double = 10, n: Int = 8) -> UsualRangeValue {
        UsualRangeValue(lo: lo, hi: hi, median: median, n: n, full: false)
    }

    private func card(rides: Int = 6, used: Double? = 13, usual: UsualRangeValue? = nil, other: Double? = nil, state: SmartPromptState = SmartPromptState(),
                      answered: Bool = false, at: Int64? = nil) -> SmartPromptCard? {
        let explanation = other.map { RideExplanation(items: [], otherPct: $0) }
        return SmartPrompt.card(rideId: "r1", routeRides: rides, usedPct: used, usualUsed: usual ?? range(), explanation: explanation,
                                alreadyAnswered: answered, state: state, nowMs: at ?? now, utcOffsetMin: off)
    }

    // MARK: Smart prompt

    func testGates() {
        XCTAssertEqual(card()?.text, "This ride used 4% more battery than usual. Wind, rush hour and load don't explain it. Anything different?")
        XCTAssertNil(card(rides: 4))                       // route needs 5 rides
        XCTAssertNil(card(used: 10.5))                      // extra under the 2% step
        XCTAssertNil(card(used: nil))
        XCTAssertNil(card(other: 1.5))   // the factors explain all but 1.5%
        XCTAssertNotNil(card(other: 2))                     // exactly 2% unexplained
        XCTAssertNil(card(other: 1.9))
        XCTAssertNil(card(answered: true))
    }

    func testOnceADay() {
        let shown = SmartPrompt.afterShown(SmartPromptState(), rideId: "r0", nowMs: now, utcOffsetMin: off)
        XCTAssertNil(card(state: shown))                                      // another ride's card went today
        XCTAssertNotNil(card(state: shown, at: now + 86_400_000))             // next day
        let same = SmartPrompt.afterShown(SmartPromptState(), rideId: "r1", nowMs: now, utcOffsetMin: off)
        XCTAssertNotNil(card(state: same))                                    // the same ride keeps its card until answered
    }

    func testTwoDismissalsPauseSevenDays() {
        var s = SmartPromptState()
        s = SmartPrompt.afterDismiss(s, nowMs: now)
        XCTAssertNil(s.pausedUntilMs)
        XCTAssertNotNil(card(state: s))
        s = SmartPrompt.afterDismiss(s, nowMs: now)
        XCTAssertEqual(s.pausedUntilMs, now + 7 * 86_400_000)
        XCTAssertNil(card(state: s, at: now + 6 * 86_400_000))
        XCTAssertNotNil(card(state: s, at: now + 7 * 86_400_000 + 1))
        // an answer clears the streak
        var t = SmartPrompt.afterDismiss(SmartPromptState(), nowMs: now)
        t = SmartPrompt.afterAnswer(t)
        XCTAssertEqual(t.dismissStreak, 0)
    }

    func testAnswers() {
        XCTAssertEqual(SmartAnswer.allCases.map(\.title), ["Light load", "Heavy load", "Tyres felt soft", "Rode differently", "Not sure"])
        XCTAssertEqual(SmartAnswer.light.loadLevel?.presetKg, 5)
        XCTAssertEqual(SmartAnswer.heavy.loadLevel?.presetKg, 15)
        XCTAssertTrue(SmartAnswer.tyresSoft.excludesFromUsual && SmartAnswer.tyresSoft.makesTyresDue)
        XCTAssertTrue(SmartAnswer.rodeDifferently.excludesFromUsual && !SmartAnswer.rodeDifferently.makesTyresDue)
        XCTAssertFalse(SmartAnswer.notSure.excludesFromUsual)
        XCTAssertNil(SmartAnswer.notSure.loadLevel)
    }

    func testLoadedTagLabels() {
        XCTAssertEqual(LoadLevel.label(level: nil, kg: nil), "Not set")
        XCTAssertEqual(LoadLevel.label(level: "none", kg: 0), "None")
        XCTAssertEqual(LoadLevel.label(level: "light", kg: 5), "Light (5 kg)")
        XCTAssertEqual(LoadLevel.label(level: "heavy", kg: 15), "Heavy (15 kg)")
        XCTAssertEqual(LoadLevel.label(level: "custom", kg: 7.4), "7 kg")
    }

    func testPromptWordingHasNoRewardWords() {
        let text = card()?.text ?? ""
        XCTAssertTrue(InsightText.bannedIn(text).isEmpty)
        for a in SmartAnswer.allCases { XCTAssertTrue(InsightText.bannedIn(a.title).isEmpty) }
    }

    // MARK: Heat

    private func usual(rise: Double = 30, km: Double = 6, air: Double? = 22, n: Int = 6) -> [HeatRide] {
        (0..<n).map { HeatRide(riseC: rise + Double($0 % 3), distanceKm: km, airTempC: air) }
    }

    func testPeakCardOnlyAtHot() {
        XCTAssertEqual(InsightCatalogue.heatPeak(rideId: "r", routeId: nil, peakC: 92, riseC: 68, nowMs: now).first?.text, "Peak 92 \u{00B0}C \u{00B7} +68 \u{00B0}C")
        XCTAssertTrue(InsightCatalogue.heatPeak(rideId: "r", routeId: nil, peakC: 89.4, riseC: 60, nowMs: now).isEmpty)
        XCTAssertFalse(InsightCatalogue.heatPeak(rideId: "r", routeId: nil, peakC: 90, riseC: 60, nowMs: now).isEmpty)
        // a learned limit moves it
        let learned = HeatLimits.limits(eventTempsC: [78, 82])
        XCTAssertEqual(learned.hotC, 73)
        XCTAssertEqual(learned.veryHotC, 83)
        XCTAssertFalse(InsightCatalogue.heatPeak(rideId: "r", routeId: nil, peakC: 75, riseC: 40, hotC: learned.hotC, nowMs: now).isEmpty)
        XCTAssertEqual(HeatLimits.limits(eventTempsC: [78]).hotC, 90)        // one event is not enough
    }

    func testHotDay() {
        let ride = HeatRide(riseC: 42, distanceKm: 6, airTempC: 33)
        let found = InsightCatalogue.heatHotDay(rideId: "r", routeId: "A", ride: ride, routeRides: usual(), nowMs: now)
        XCTAssertEqual(found.first?.text, "Hot day (33 \u{00B0}C): scooter ran 11 \u{00B0}C hotter than usual on this route \u{00B7} based on 6 rides.")
        // below each gate
        XCTAssertTrue(InsightCatalogue.heatHotDay(rideId: "r", routeId: "A", ride: HeatRide(riseC: 42, distanceKm: 6, airTempC: 29), routeRides: usual(), nowMs: now).isEmpty)
        XCTAssertTrue(InsightCatalogue.heatHotDay(rideId: "r", routeId: "A", ride: HeatRide(riseC: 35, distanceKm: 6, airTempC: 33), routeRides: usual(), nowMs: now).isEmpty)
        XCTAssertTrue(InsightCatalogue.heatHotDay(rideId: "r", routeId: "A", ride: ride, routeRides: usual(n: 4), nowMs: now).isEmpty)
    }

    func testRanHotterNeedsRateAndSimilarAir() {
        let ride = HeatRide(riseC: 48, distanceKm: 6, airTempC: 22)        // 8 C/km against ~5.2
        XCTAssertNotNil(InsightCatalogue.heatRanHotter(rideId: "r", routeId: "A", ride: ride, routeRides: usual(), nowMs: now).first)
        // just under +30%
        let near = HeatRide(riseC: 39, distanceKm: 6, airTempC: 22)         // 6.5 against 5.17 = +26%
        XCTAssertTrue(InsightCatalogue.heatRanHotter(rideId: "r", routeId: "A", ride: near, routeRides: usual(), nowMs: now).isEmpty)
        // rides in very different air temperature are not compared
        XCTAssertTrue(InsightCatalogue.heatRanHotter(rideId: "r", routeId: "A", ride: ride, routeRides: usual(air: 10), nowMs: now).isEmpty)
        XCTAssertTrue(InsightCatalogue.heatRanHotter(rideId: "r", routeId: "A", ride: ride, routeRides: usual(n: 4), nowMs: now).isEmpty)
    }

    func testHotDayBeatsRanHotter() {
        let ride = HeatRide(riseC: 60, distanceKm: 6, airTempC: 33)
        let both = InsightCatalogue.heatAfter(rideId: "r", routeId: "A", peakC: 92, ride: ride, routeRides: usual(air: 33), nowMs: now)
        XCTAssertEqual(both.map(\.type), [.heatPeak, .heatHotDay])
        let hotter = InsightCatalogue.heatAfter(rideId: "r", routeId: "A", peakC: 60, ride: HeatRide(riseC: 48, distanceKm: 6, airTempC: 22), routeRides: usual(), nowMs: now)
        XCTAssertEqual(hotter.map(\.type), [.heatRanHotter])
        XCTAssertTrue(both.allSatisfy { InsightText.bannedIn($0.text).isEmpty })
    }

    func testHeatClasses() {
        XCTAssertEqual(InsightType.heatPeak.insightClass, .safety)
        XCTAssertEqual(InsightType.heatHotDay.insightClass, .surprise)
        XCTAssertEqual(InsightType.heatRanHotter.insightClass, .surprise)
    }
}
