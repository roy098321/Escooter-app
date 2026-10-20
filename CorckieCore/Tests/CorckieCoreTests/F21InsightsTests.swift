@testable import CorckieCore
import XCTest

/// F-21 (P6-4 chunk 3b): the insight engines, their maths and the certainty gate, on made-up rides only.
final class F21InsightsTests: XCTestCase {
    typealias S = InsightSamplesF21

    // MARK: maths

    func test_leastSquares_recoversAQuadratic() throws {
        let xs = stride(from: 10.0, through: 40, by: 2).map { $0 }
        let rows = xs.map { [1, $0, $0 * $0] }
        let y = xs.map { 2 - 0.1 * $0 + 0.002 * $0 * $0 }
        let fit = try XCTUnwrap(InsightMath.leastSquares(rows: rows, y: y))
        XCTAssertEqual(fit.beta[0], 2, accuracy: 1e-4)
        XCTAssertEqual(fit.beta[1], -0.1, accuracy: 1e-6)
        XCTAssertEqual(fit.beta[2], 0.002, accuracy: 1e-8)
        XCTAssertNil(InsightMath.leastSquares(rows: [[1, 2], [1, 2], [1, 2]], y: [1, 2, 3]), "a singular system gives nil")
        XCTAssertNil(InsightMath.leastSquares(rows: [[1, 2]], y: [1]), "fewer rows than coefficients")
    }

    func test_robustFit_dropsAWildPoint() throws {
        var rows: [[Double]] = [], y: [Double] = []
        for i in 0..<20 {
            rows.append([1, Double(i)])
            y.append(1 + 0.5 * Double(i) + (i % 2 == 0 ? 0.01 : -0.01))
        }
        y[7] = 40
        let r = try XCTUnwrap(InsightMath.robustLeastSquares(rows: rows, y: y))
        XCTAssertFalse(r.kept.contains(7))
        XCTAssertEqual(r.fit.beta[1], 0.5, accuracy: 0.01)
    }

    func test_tCritAndWelch() throws {
        XCTAssertEqual(InsightMath.tCrit(5), 2.57)
        XCTAssertEqual(InsightMath.tCrit(100), 1.98)
        let d = try XCTUnwrap(InsightMath.meanDifference([10, 11, 12], [5, 6, 7]))
        XCTAssertEqual(d.diff, 5, accuracy: 1e-9)
        XCTAssertGreaterThan(d.diff / d.se, 3)
        XCTAssertNil(InsightMath.meanDifference([1], [2, 3]))
    }

    // MARK: certainty gate

    func test_gate_thresholds() {
        XCTAssertEqual(InsightGate.level(n: 8, mediumN: 8, highN: 15, t: 2.0), .medium)
        XCTAssertEqual(InsightGate.level(n: 7, mediumN: 8, highN: 15, t: 9), .low, "too few samples is low whatever the effect")
        XCTAssertEqual(InsightGate.level(n: 30, mediumN: 8, highN: 15, t: 1.9), .low, "an interval that includes no difference is low")
        XCTAssertEqual(InsightGate.level(n: 15, mediumN: 8, highN: 15, t: 3), .high)
        XCTAssertEqual(InsightGate.level(n: 15, mediumN: 8, highN: 15, t: -3.5), .high, "the sign is the engine's business")
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 30, rides: 8, curvatureT: 3, halfWidthKmh: 2.5), .high)
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 30, rides: 8, curvatureT: 3, halfWidthKmh: 3), .medium)
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 30, rides: 8, curvatureT: 3, halfWidthKmh: 4.5), .low, "a wide interval stays hidden")
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 11, rides: 8, curvatureT: 9, halfWidthKmh: 1), .low)
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 40, rides: 3, curvatureT: 9, halfWidthKmh: 1), .low)
        XCTAssertEqual(InsightGate.sweetSpot(stretches: 40, rides: 9, curvatureT: -5, halfWidthKmh: 1), .low, "a curve that bends down has no sweet spot")
        XCTAssertEqual(InsightGate.departure(bestN: 3, habitN: 9, gainS: 300, t: 2.5), .medium)
        XCTAssertEqual(InsightGate.departure(bestN: 6, habitN: 9, gainS: 300, t: 4), .high)
        XCTAssertEqual(InsightGate.departure(bestN: 6, habitN: 9, gainS: 100, t: 9), .low, "under 2 min is not worth a card")
        XCTAssertEqual(InsightGate.creep(recentN: 10, referenceN: 12, share: 0.09, t: 3.2), .high)
        XCTAssertEqual(InsightGate.creep(recentN: 8, referenceN: 8, share: 0.09, t: 2.1), .medium)
        XCTAssertEqual(InsightGate.creep(recentN: 10, referenceN: 20, share: 0.04, t: 9), .low, "under 5 % is not worth a card")
        XCTAssertEqual(InsightGate.creep(recentN: 10, referenceN: 20, share: -0.09, t: -9), .low, "less battery is no maintenance")
        XCTAssertEqual(InsightGate.wind(rides: 8, slopeT: 2.2), .medium)
        XCTAssertEqual(InsightGate.wind(rides: 15, slopeT: 3.1), .high)
        XCTAssertEqual(InsightGate.wind(rides: 20, slopeT: -4), .low)
        XCTAssertFalse(CertaintyLevel.low.shown)
        XCTAssertTrue(CertaintyLevel.medium.shown && CertaintyLevel.high.shown)
    }

    // MARK: speed sweet spot

    func test_sweetSpot_findsTheLowestPoint() throws {
        let card = try XCTUnwrap(SweetSpotInsight.make(rides: S.sweetRides(9), context: S.sweetContext()).shown)
        XCTAssertEqual(card.kind, .pattern)
        XCTAssertEqual(card.certainty.level, .high)
        XCTAssertLessThanOrEqual(card.headlineWords, 8)
        let words = card.headline.split(separator: " ")
        let best = try XCTUnwrap(Int(words[words.count - 2]))
        XCTAssertTrue((26...30).contains(best), card.headline)
        XCTAssertEqual(card.value, "0.9")
        XCTAssertEqual(card.unit, "%")
        XCTAssertTrue(card.context.hasPrefix("per km \u{00B7} vs "), card.context)
        XCTAssertEqual(card.basedOn, "Based on 9 rides")
        let band = try XCTUnwrap(card.chart?.band)
        XCTAssertTrue(band.contains(28), "the interval holds the true 28 km/h: \(band)")
        XCTAssertLessThan(band.upperBound - band.lowerBound, 5)
        XCTAssertGreaterThanOrEqual(card.chart?.dots.count ?? 0, 5)
        XCTAssertTrue(card.certainty.interval.hasPrefix("Sweet spot between "))
        XCTAssertEqual(card.evidence.rides, 9)
    }

    func test_sweetSpot_whatIfIsHonestAndPointsTheRightWay() throws {
        let ctx = S.sweetContext()
        let card = try XCTUnwrap(SweetSpotInsight.make(rides: S.sweetRides(9), context: ctx).card)
        let base = try XCTUnwrap(card.whatIf.first { $0.isBaseline })
        // the baseline is the honest range from full: (100 − 5) / 2.9 %/km, no margin
        XCTAssertTrue(base.items[0].text.hasPrefix("~\(Int((95 / 2.9).rounded())) km range"), base.items[0].text)
        XCTAssertTrue(base.items[0].text.hasSuffix("19 min"))
        let faster = card.whatIf.filter { $0.note.hasPrefix("(+") }
        XCTAssertFalse(faster.isEmpty)
        for r in faster {
            XCTAssertEqual(r.items[0].tone, .worse, "faster than the usual cruise (above the sweet spot) costs range: \(r.items[0].text)")
            XCTAssertEqual(r.items.count, 2)
            XCTAssertEqual(r.items[1].tone, .better, "and saves time")
        }
    }

    func test_sweetSpot_hiddenWhenUnsure() {
        XCTAssertNil(SweetSpotInsight.make(rides: S.sweetRides(9, bend: 0, noise: 0.05), context: S.sweetContext()).shown, "a flat curve has no sweet spot")
        if case .learning(let topic, let why) = SweetSpotInsight.make(rides: S.sweetRides(1), context: S.sweetContext()) {
            XCTAssertEqual(topic, .sweetSpot)
            XCTAssertTrue(why.contains("steady stretches"), why)
        } else {
            XCTFail("one ride is still learning")
        }
        let windy = S.sweetRides(9).map { r -> SweetSpotRide in
            var w = r
            w.strongWind = true
            return w
        }
        XCTAssertNil(SweetSpotInsight.make(rides: windy, context: S.sweetContext()).card, "strong-wind rides are left out")
    }

    func test_stretches_cutClimbsGapsAndStops() {
        var cuts = SweetSpotInsight.Cuts()
        let flat = (0..<90).map { SpeedSample(tS: Double($0), speedKmh: 28, powerW: 200, altM: 10) }
        XCTAssertEqual(SweetSpotInsight.stretches(rideId: "a", samples: flat, cuts: &cuts).count, 1)
        let climb = (0..<90).map { SpeedSample(tS: Double($0), speedKmh: 28, powerW: 400, altM: 10 + 0.4 * Double($0)) }
        XCTAssertTrue(SweetSpotInsight.stretches(rideId: "b", samples: climb, cuts: &cuts).isEmpty)
        XCTAssertEqual(cuts.climbs, 1)
        let short = (0..<50).map { SpeedSample(tS: Double($0), speedKmh: 28, powerW: 200) }
        XCTAssertTrue(SweetSpotInsight.stretches(rideId: "c", samples: short, cuts: &cuts).isEmpty, "under a minute is not steady")
        let gap = (0..<90).map { SpeedSample(tS: Double($0) + ($0 >= 45 ? 10 : 0), speedKmh: 28, powerW: 200) }
        XCTAssertTrue(SweetSpotInsight.stretches(rideId: "d", samples: gap, cuts: &cuts).isEmpty, "a 10 s gap breaks the stretch")
        let changing = (0..<90).map { SpeedSample(tS: Double($0), speedKmh: 15 + Double($0) / 5, powerW: 200) }
        XCTAssertTrue(SweetSpotInsight.stretches(rideId: "e", samples: changing, cuts: &cuts).isEmpty, "speeding up is not steady")
        let long = (0..<300).map { SpeedSample(tS: Double($0), speedKmh: 28, powerW: 200) }
        XCTAssertEqual(SweetSpotInsight.stretches(rideId: "f", samples: long, cuts: &cuts).count, 2, "long stretches are cut at 2 min")
    }

    // MARK: departure time

    func test_departure_earlierBeatsHabit() throws {
        let card = try XCTUnwrap(DepartureInsight.make(rides: S.departureRides(), destination: "Work", utcOffsetMin: 180).shown)
        XCTAssertEqual(card.value, "\u{2212}6")
        XCTAssertEqual(card.unit, "min")
        XCTAssertEqual(card.context, "to Work")
        XCTAssertTrue(card.headline.hasPrefix("Leaving at 7:"), card.headline)
        XCTAssertTrue(card.headline.hasSuffix("beats 8:10"), card.headline)
        XCTAssertLessThanOrEqual(card.headlineWords, 8)
        XCTAssertTrue(card.action.hasPrefix("Try leaving by 7:"), card.action)
        XCTAssertEqual(card.certainty.level, .high)
        XCTAssertTrue(card.whatIf.contains { $0.isBaseline && $0.label == "Leave 8:10" })
        let earlier = try XCTUnwrap(card.whatIf.first { $0.note == "(\u{2212}30 min)" })
        XCTAssertEqual(earlier.items[0].tone, .better, earlier.items[0].text)
    }

    func test_departure_hiddenWhenSmallOrFew() {
        XCTAssertNil(DepartureInsight.make(rides: S.departureRides(gainMin: 1), destination: nil, utcOffsetMin: 180).shown, "1 min is not worth it")
        XCTAssertNil(DepartureInsight.make(rides: S.departureRides(habit: 3, early: 2), destination: nil, utcOffsetMin: 180).card, "5 rides is learning")
        XCTAssertNil(DepartureInsight.make(rides: S.departureRides(early: 2), destination: nil, utcOffsetMin: 180).shown, "2 early rides cannot say")
    }

    // MARK: battery-use creep

    func test_creep_findsTheIncrease() throws {
        let card = try XCTUnwrap(CreepInsight.make(rides: S.creepRides(), reservePct: 5, utcOffsetMin: 180).shown)
        XCTAssertEqual(card.kind, .maintenance)
        XCTAssertEqual(card.value, "+9")
        XCTAssertEqual(card.action, "Check tyre pressure (usually the cause)")
        XCTAssertTrue(card.headline.hasPrefix("Using more battery than in "))
        XCTAssertLessThanOrEqual(card.headlineWords, 8)
        XCTAssertEqual(card.certainty.level, .high)
        XCTAssertTrue(card.basedOn.hasPrefix("Last 10 rides vs "))
        let back = try XCTUnwrap(card.whatIf.first { $0.label.hasPrefix("Back to ") })
        XCTAssertEqual(back.items[0].tone, .better)
    }

    func test_creep_hiddenWithoutIncrease() {
        XCTAssertNil(CreepInsight.make(rides: S.creepRides(increase: 0), reservePct: 5, utcOffsetMin: 180).shown)
        XCTAssertNil(CreepInsight.make(rides: S.creepRides(increase: -0.1), reservePct: 5, utcOffsetMin: 180).shown)
        XCTAssertNil(CreepInsight.make(rides: S.creepRides(reference: 5), reservePct: 5, utcOffsetMin: 180).card, "5 earlier rides is learning")
    }

    // MARK: today's wind

    func test_wind_leaveWithCarriesTheMargin_shownNumberIsHonest() throws {
        let card = try XCTUnwrap(WindTodayInsight.make(history: S.windHistory(), today: S.windToday(), utcOffsetMin: 180).shown)
        XCTAssertEqual(card.kind, .today)
        // 0.03 %/km per km/h × 26 km/h × 12 km = 9.4 % extra (honest)
        XCTAssertEqual(card.value, "+9")
        XCTAssertEqual(card.headline, "Headwind on the way home")
        // 5 % reserve + (11 + 9.4) × 1.1 = 27.4 → 30 %
        XCTAssertEqual(card.action, "Leave Work with at least 30 %")
        XCTAssertEqual(WindTodayInsight.leaveWith(usualPct: 11, extraPct: 9.4, reservePct: 5), 30)
        XCTAssertEqual(WindTodayInsight.leaveWith(usualPct: 90, extraPct: 20, reservePct: 5), 100)
        XCTAssertTrue(card.basedOn.hasPrefix("Wind 28 km/h from the north-west"), card.basedOn)
        XCTAssertEqual(WindTodayInsight.compass(0), "north")
        XCTAssertEqual(WindTodayInsight.compass(200), "south")
    }

    func test_wind_onlyWhenItMatters() {
        XCTAssertNil(WindTodayInsight.make(history: S.windHistory(), today: S.windToday(headwindKmh: 8), utcOffsetMin: 180).card, "light wind: no card")
        XCTAssertNil(WindTodayInsight.make(history: S.windHistory(), today: S.windToday(headwindKmh: -25), utcOffsetMin: 180).card, "tailwind: no card")
        XCTAssertNil(WindTodayInsight.make(history: S.windHistory(5), today: S.windToday(), utcOffsetMin: 180).card, "5 rides is learning")
        XCTAssertNil(WindTodayInsight.make(history: S.windHistory(slope: 0, noise: 0.2), today: S.windToday(), utcOffsetMin: 180).shown,
                     "no clear wind cost: hidden")
    }

    // MARK: board

    func test_board_atMostThree_noTodayCard_learningLine() {
        let board = InsightBoard.make(S.outcomes())
        XCTAssertEqual(board.cards.count, 3)
        XCTAssertFalse(board.cards.contains { $0.kind == .today })
        XCTAssertTrue(board.learning.isEmpty)
        XCTAssertNil(board.learningLine)
        for c in board.cards { XCTAssertLessThanOrEqual(c.headlineWords, 8, c.headline) }
        let sparse = InsightBoard.make([.learning(.sweetSpot, "x"), .learning(.departure, "y"), .learning(.wind, "z")])
        XCTAssertTrue(sparse.cards.isEmpty)
        XCTAssertEqual(sparse.learning, [.sweetSpot, .departure])
        XCTAssertEqual(sparse.learningLine, "Still learning your speed sweet spot and the best time to leave. More rides make these clear.")
    }

    func test_retiredTypes() {
        XCTAssertTrue(InsightType.retiredF21.contains(.heatPeak))
        XCTAssertTrue(InsightType.retiredF21.contains(.firstRide))
        XCTAssertFalse(InsightType.retiredF21.contains(.q4After))
    }
}
