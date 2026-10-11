import XCTest
@testable import CorckieCore

/// M6-01 (Q23): choice points from made-up ride sets (`ChoiceSamples`), option times, the gates (3 rides per option, beat the
/// fastest ridden way by 1 min + 10%), ties, an option seen once, factor adjustment, the path to follow and the card text.
final class FastestCombinationTests: XCTestCase {
    typealias S = ChoiceSamples.Spec

    private func combo(_ a: FastestAnswer, file: StaticString = #filePath, line: UInt = #line) -> FastestCombo? {
        guard case .combination(let c) = a.state else {
            XCTFail("expected a combination, got \(a.state)", file: file, line: line)
            return nil
        }
        return c
    }

    // MARK: Detection

    func testTwoChoicePointsWithTwoOptionsEach() {
        let (set, _) = ChoiceSamples.answer(ChoiceSamples.nineRides)
        XCTAssertEqual(set.points.count, 2)
        guard set.points.count == 2 else { return }
        let p1 = set.points[0], p2 = set.points[1]
        XCTAssertEqual(p1.posOnRefM, 800, accuracy: 60, "split of the park detour")
        XCTAssertEqual(p1.rejoinOnRefM, 1_400, accuracy: 60)
        XCTAssertEqual(p2.posOnRefM, 2_400, accuracy: 60)
        XCTAssertEqual(p2.rejoinOnRefM, 3_000, accuracy: 60)
        XCTAssertEqual(p1.options.count, 2)
        XCTAssertEqual(p2.options.count, 2)
        XCTAssertTrue(p1.options[0].isReference, "the reference's own stretch is always an option, first")
        XCTAssertEqual(set.costs.count, 18, "9 rides x 2 choice points")
        // every ride has exactly one option per choice point
        for p in set.points {
            XCTAssertEqual(Set(set.costs.filter { $0.choicePointId == p.id }.map(\.rideId)).count, 9)
        }
        // the park detour costs ~80 s on its stretch, the usual way ~168 s on the same stretch (560 of 600 m)
        let park = set.costs.filter { $0.optionId == p1.options[1].id }.map(\.timeS)
        let usual = set.costs.filter { $0.optionId == p1.options[0].id }.map(\.timeS)
        XCTAssertEqual(park.count, 3)
        XCTAssertEqual(usual.count, 6)
        XCTAssertEqual(Geo.median(usual)!, 168, accuracy: 8)
        XCTAssertEqual(Geo.median(park)!, 76, accuracy: 8)
        XCTAssertNotNil(set.costs.first?.usedPct)
        XCTAssertNotNil(set.costs.first?.energyWh)
    }

    func testIdsAreStableWhenRidesAreAdded() {
        let a = ChoiceSamples.answer(ChoiceSamples.nineRides).set
        let b = ChoiceSamples.answer(ChoiceSamples.nineRides + [S(.usual, left: false)]).set
        XCTAssertEqual(a.points.map(\.id), b.points.map(\.id))
        XCTAssertEqual(a.points.flatMap { $0.options.map(\.id) }, b.points.flatMap { $0.options.map(\.id) })
    }

    func testOnlyOneWayRiddenHasNoChoicePoints() {
        let (set, answer) = ChoiceSamples.answer(Array(repeating: S(.usual, left: false), count: 5))
        XCTAssertTrue(set.points.isEmpty)
        XCTAssertEqual(answer.state, .noChoicePoints)
        XCTAssertNil(FastestCard.make(answer), "S9: no section")
    }

    func testGpsGapInsideAnOptionIsLeftOut() {
        let specs = ChoiceSamples.nineRides + [S(.park, left: false, gapM: 900...1_150)]
        let (set, _) = ChoiceSamples.answer(specs)
        XCTAssertEqual(set.points.count, 2)
        let p1 = set.points.first!
        XCTAssertFalse(set.costs.contains { $0.rideId == "c10" && $0.choicePointId == p1.id }, "no time across a GPS gap")
        XCTAssertTrue(set.costs.contains { $0.rideId == "c10" && $0.choicePointId != p1.id })
    }

    // MARK: Fastest combination

    func testKnownFastestCombinationIsRecovered() {
        let (_, answer) = ChoiceSamples.answer(ChoiceSamples.nineRides)
        guard let c = combo(answer) else { return }
        XCTAssertEqual(c.ways.count, 2)
        XCTAssertFalse(c.ways[0].isReference, "park at the first choice point")
        XCTAssertFalse(c.ways[1].isReference, "left at the second")
        // usual-usual ~ 467 + 180 + 170 = 817 s; park + left ~ 467 + 80 + 75 = 622 s; best ridden: park + usual ~ 717 s
        // the model puts the few metres at both ends of an option into the shared stretches, so ~634 s (a real ride: ~622 s)
        XCTAssertEqual(c.timeS, 628, accuracy: 15)
        XCTAssertEqual(c.bestRealS, 717, accuracy: 10)
        XCTAssertEqual(c.savingS, 89, accuracy: 12)
        XCTAssertEqual(c.basedOnN, 3)
        XCTAssertEqual(c.ways[0].savingS, 92, accuracy: 10, "saving over the usual way at that place (M6-02 prompt)")
        XCTAssertGreaterThan(c.ways[0].apartM, 100, "S2: options well apart")
        XCTAssertFalse(c.factorsApplied)
    }

    func testFollowPathStaysOnRiddenPaths() {
        let made = ChoiceSamples.rides(ChoiceSamples.nineRides)
        let set = ChoicePointDetector.detect(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference, rides: made.choice,
                                             routeLengthM: ChoiceSamples.routeM)
        let answer = FastestCombination.answer(CombinationInput(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference,
                                                                routeLengthM: ChoiceSamples.routeM, choices: set, rides: made.rides,
                                                                nowMs: ChoiceSamples.t0 + 20 * ChoiceSamples.day))
        guard let c = combo(answer) else { return }
        let ridden = made.choice.map { r in r.fixes.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
        for p in c.path {
            let nearest = ridden.map { Geo.distanceToPathM(p, $0) }.min() ?? .infinity
            XCTAssertLessThan(nearest, 30, "navigation only along ridden paths")
        }
        XCTAssertLessThan(Geo.distanceToPathM(ChoiceSamples.geo((150, 1_100)), c.path), 15, "goes through the park")
        XCTAssertLessThan(Geo.distanceToPathM(ChoiceSamples.geo((-120, 2_700)), c.path), 15, "and left at the lights")
        XCTAssertEqual(Geo.distanceM(c.path.first!, ChoiceSamples.geo((0, 0))), 0, accuracy: 15)
        XCTAssertEqual(Geo.distanceM(c.path.last!, ChoiceSamples.geo((0, 4_000))), 0, accuracy: 15)
        XCTAssertEqual(Geo.pathLengthM(c.path), 4_000 - 600 - 600 + 760 + 712, accuracy: 80)
    }

    func testRiddenAsAWholeIsANormalVariant() {
        let (_, answer) = ChoiceSamples.answer(ChoiceSamples.nineRides + [S(.park, left: true)])
        guard case .alreadyRidden(let c) = answer.state else { return XCTFail("\(answer.state)") }
        XCTAssertFalse(c.ways[0].isReference)
        let card = FastestCard.make(answer)!
        XCTAssertFalse(card.canFollow)
        XCTAssertTrue(card.detail.hasSuffix("you already ride it"), card.detail)
    }

    func testSavingUnderOneMinutePlusMarginIsNotWorthIt() {
        // the park only saves ~55 s at its stretch: park + left beats the best ridden way (usual + left) by ~55 s < 66 s
        let specs = ChoiceSamples.nineRides.map { s -> S in
            var s = s
            if s.way1 == .park { s.way1S = 125 }
            return s
        }
        let (_, answer) = ChoiceSamples.answer(specs)
        guard case .notWorthIt(let c) = answer.state else { return XCTFail("\(answer.state)") }
        XCTAssertGreaterThan(c.savingS, 30)
        XCTAssertLessThan(c.savingS, 66)
        let card = FastestCard.make(answer)!
        XCTAssertEqual(card.headline, "Fastest combination: no faster mix yet")
        XCTAssertFalse(card.canFollow)
    }

    func testMarginDecidesNotTheShownNumber() {
        // ~62 s saving: above the 1 min of T95, below the 66 s the decision uses (G2)
        let specs = ChoiceSamples.nineRides.map { s -> S in
            var s = s
            if s.way1 == .park { s.way1S = 118 }
            return s
        }
        let (_, answer) = ChoiceSamples.answer(specs)
        if case .combination(let c) = answer.state { XCTAssertGreaterThanOrEqual(c.savingS, 66) }
        if case .notWorthIt(let c) = answer.state { XCTAssertLessThan(c.savingS, 66) }
    }

    func testTieGoesToTheUsualWay() {
        // left at the lights takes as long as the usual way (same time on the same stretch): the usual way is kept there
        let specs = ChoiceSamples.nineRides.map { s -> S in
            var s = s
            if s.left { s.way2S = 163 }
            return s
        }
        let pickTie = FastestCombination.pick([
            OptionEstimate(optionId: "b", choicePointId: "cp", name: "left", isReference: false, rides: 9, timeS: 100.4, lengthM: 700),
            OptionEstimate(optionId: "a", choicePointId: "cp", name: "usual way", isReference: true, rides: 3, timeS: 100.0, lengthM: 600)
        ])
        XCTAssertEqual(pickTie?.optionId, "a", "within 1 s the usual way wins")
        let moreRidden = FastestCombination.pick([
            OptionEstimate(optionId: "x", choicePointId: "cp", name: "x", isReference: false, rides: 3, timeS: 90.2, lengthM: 700),
            OptionEstimate(optionId: "y", choicePointId: "cp", name: "y", isReference: false, rides: 5, timeS: 90.0, lengthM: 700)
        ])
        XCTAssertEqual(moreRidden?.optionId, "y", "then the more ridden")
        let clear = FastestCombination.pick([
            OptionEstimate(optionId: "a", choicePointId: "cp", name: "usual way", isReference: true, rides: 9, timeS: 102, lengthM: 600),
            OptionEstimate(optionId: "b", choicePointId: "cp", name: "left", isReference: false, rides: 3, timeS: 100, lengthM: 700)
        ])
        XCTAssertEqual(clear?.optionId, "b", "2 s is no tie")
        let (_, answer) = ChoiceSamples.answer(specs)
        // park + usual way at the second point was ridden 3 times: a normal variant, or no mix under the gate
        switch answer.state {
        case .alreadyRidden(let c):
            XCTAssertFalse(c.ways[0].isReference)
        case .notWorthIt, .combination:
            break
        default:
            XCTFail("\(answer.state)")
        }
    }

    // MARK: Gates

    func testEachOptionNeedsThreeRides() {
        // left at the lights only twice: not used, the usual way is kept at that place (park + usual way = ridden)
        let specs = Array(repeating: S(.usual, left: false), count: 3) + Array(repeating: S(.park, left: false), count: 3)
            + Array(repeating: S(.usual, left: true), count: 2)
        let (_, answer) = ChoiceSamples.answer(specs)
        guard case .alreadyRidden(let c) = answer.state else { return XCTFail("\(answer.state)") }
        XCTAssertTrue(c.ways[1].isReference)
        XCTAssertEqual(answer.waiting.count, 1)
        XCTAssertEqual(answer.waiting.first?.have, 2)
        XCTAssertEqual(FastestCard.make(answer)?.waiting.first?.hasSuffix(": 2 of 3 rides"), true)
    }

    func testNoOptionAtThreeRidesIsNotEnoughData() {
        let specs = Array(repeating: S(.usual, left: false), count: 2) + Array(repeating: S(.park, left: false), count: 2)
        let (_, answer) = ChoiceSamples.answer(specs)
        guard case .notEnoughData(let have, let need, _) = answer.state else { return XCTFail("\(answer.state)") }
        XCTAssertEqual(need, 3)
        XCTAssertEqual(have, 2)
        let card = FastestCard.make(answer)!
        XCTAssertTrue(card.filling)
        XCTAssertEqual(card.headline, "Fastest combination: not enough data yet")
        XCTAssertFalse(card.canFollow)
    }

    func testOptionSeenOnceWaitsAndChangesNothing() {
        let (set, answer) = ChoiceSamples.answer(ChoiceSamples.nineRides + [S(.other, left: false)])
        XCTAssertEqual(set.points.first?.options.count, 3, "a third way at the first choice point")
        XCTAssertEqual(answer.waiting.map(\.have), [1])
        guard let c = combo(answer) else { return }
        XCTAssertEqual(c.timeS, 628, accuracy: 15)
        XCTAssertFalse(c.ways[0].optionId.hasSuffix(":c10"), "seen once is never chosen")
    }

    func testOldAndExcludedRidesAreLeftOut() {
        let made = ChoiceSamples.rides(ChoiceSamples.nineRides)
        let set = ChoicePointDetector.detect(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference, rides: made.choice,
                                             routeLengthM: ChoiceSamples.routeM)
        var rides = made.rides
        rides[6].excluded = true            // one "left" ride excluded from the usual → only 2 left
        let a = FastestCombination.answer(CombinationInput(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference,
                                                           routeLengthM: ChoiceSamples.routeM, choices: set, rides: rides,
                                                           nowMs: ChoiceSamples.t0 + 20 * ChoiceSamples.day))
        guard case .alreadyRidden = a.state else { return XCTFail("\(a.state)") }
        let late = FastestCombination.answer(CombinationInput(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference,
                                                              routeLengthM: ChoiceSamples.routeM, choices: set, rides: made.rides,
                                                              nowMs: ChoiceSamples.t0 + 400 * ChoiceSamples.day))
        guard case .notEnoughData = late.state else { return XCTFail("a year later: \(late.state)") }
    }

    // MARK: Factors

    func testRushHourOnTheParkRidesIsTakenOut() {
        // the park rides were all in rush hour (+600 s per trip, ~+110 s on the park stretch): raw, the park looks slower
        let specs = ChoiceSamples.nineRides.map { s -> S in
            var s = s
            if s.way1 == .park { s.levels = ["rush"] }
            return s
        }
        let raw = ChoiceSamples.answer(specs, tripEffectsS: ["rush": 600], usedEffectsS: [:]).answer
        if case .combination(let c) = raw.state { XCTAssertTrue(c.ways[0].isReference, "raw: the park looks slower") }
        let adjusted = ChoiceSamples.answer(specs, tripEffectsS: ["rush": 600]).answer
        guard let c = combo(adjusted) else { return }
        XCTAssertFalse(c.ways[0].isReference, "with the rush-hour effect taken out the park is faster")
        XCTAssertEqual(c.timeS, 628, accuracy: 25)
        XCTAssertFalse(c.factorsApplied, "today is not rush hour")
        // leaving in rush hour today: everything slower, same choice, conditions named
        let rushToday = ChoiceSamples.answer(specs, tripEffectsS: ["rush": 600], todayLevels: ["rush"]).answer
        guard let r = combo(rushToday) else { return }
        XCTAssertEqual(r.timeS - c.timeS, 650, accuracy: 60, "today's rush hour spread over the whole way")
        XCTAssertTrue(r.factorsApplied)
        XCTAssertTrue(FastestCard.make(rushToday)!.note!.contains("today's conditions included"))
    }

    // MARK: Card + Q3 hand-off

    func testCardWording() {
        let (_, answer) = ChoiceSamples.answer(ChoiceSamples.nineRides)
        let card = FastestCard.make(answer)!
        XCTAssertTrue(card.headline.hasPrefix("Fastest combination ~10:"), card.headline)
        XCTAssertTrue(card.detail.hasSuffix(" \u{00B7} never ridden as a whole"), card.detail)
        XCTAssertTrue(card.detail.contains(" + "), card.detail)
        XCTAssertTrue(card.note!.hasPrefix("About 1:"), card.note!)
        XCTAssertTrue(card.canFollow)
        XCTAssertFalse(card.path.isEmpty)
        XCTAssertEqual(FastestCard.clock(790), "13:10")
        XCTAssertEqual(FastestCard.clock(90), "1:30")
    }

    func testNoBannedWordsInAnyState() {
        let states: [[S]] = [
            ChoiceSamples.nineRides,
            ChoiceSamples.nineRides + [S(.park, left: true)],
            Array(repeating: S(.usual, left: false), count: 2) + Array(repeating: S(.park, left: false), count: 2),
            ChoiceSamples.nineRides.map { s0 -> S in
                var s = s0
                if s.way1 == .park { s.way1S = 125 }
                return s
            },
            ChoiceSamples.nineRides + [S(.other, left: false)]
        ]
        for specs in states {
            guard let card = FastestCard.make(ChoiceSamples.answer(specs).answer) else { continue }
            for text in [card.headline, card.detail, card.note ?? ""] + card.waiting {
                XCTAssertEqual(InsightText.bannedIn(text), [], text)
            }
        }
    }

    func testQ3GetsTheParkTimes() {
        // what InsightQueries.optionTimes hands Q3: this ride's option time, the option's times, the other options' times
        let (set, _) = ChoiceSamples.answer(ChoiceSamples.nineRides)
        let p1 = set.points[0]
        let park = p1.options[1]
        let own = set.costs.filter { $0.optionId == park.id }.map(\.timeS)
        let other = set.costs.filter { $0.choicePointId == p1.id && $0.optionId != park.id }.map(\.timeS)
        let out = InsightCatalogue.q3(rideId: "c6", routeId: ChoiceSamples.routeId, optionId: park.id, optionName: "park shortcut",
                                      rideOptionTimeS: own.last!, optionTimesS: own, otherTimesS: other, nowMs: ChoiceSamples.t0)
        XCTAssertTrue(out.contains { $0.type == .q3Verdict && $0.text.contains("saves about 1.5 min") }, out.map(\.text).joined(separator: " | "))
    }
}
