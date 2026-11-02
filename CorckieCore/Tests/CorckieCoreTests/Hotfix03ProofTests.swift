import XCTest
@testable import CorckieCore

/// Hotfix 03 proof: the voice replay's pass rules, the line log and the ride summary's said-vs-real lines (made-up rides only).
final class Hotfix03ProofTests: XCTestCase {
    private func replay(_ ride: [RouteHistorySample], place: String? = nil) throws -> V09Replay.Result {
        let f = try XCTUnwrap(V09Lab.follower(history: V09Lab.history()))
        return V09Replay.run(samples: ride, route: f, whPerPct: 8.1, placeName: place)
    }

    func testMadeUpRidesPass() throws {
        for ride in [V09Lab.ride(), V09Lab.ride(sagKm: 4), V09Lab.ride(pctPerKm: { $0 < 3 ? 2 : 3.2 }), V09Lab.ride(stopAtKm: 1),
                     V09Lab.ride(slowFromKm: 2)] {
            let r = try replay(ride, place: "Uni")
            XCTAssertTrue(r.passed, r.problems.joined(separator: ", ") + " | " + r.said.map(\.line).joined(separator: " | "))
            XCTAssertNotNil(r.realArrivalPct)
        }
        let drain = try replay(V09Lab.ride(pctPerKm: { $0 < 3 ? 2 : 3.2 }))
        XCTAssertEqual(drain.realArrivalPct ?? 0, 62, accuracy: 1)
        XCTAssertEqual(drain.said.filter { $0.kind == "drop" }.map(\.value), [65])
    }

    func testVerdictCatchesContradictionsAndEarlyLateLines() {
        func line(_ m: V09Message, along: Double = 5) -> V09SaidLine {
            var n = V09Numbers()
            n.alongKm = along
            return V09SaidLine(m, numbers: n)
        }
        let higher = V09Replay.verdict(V09Replay.Result(said: [line(.sharpDrop(pct: 40)), line(.sharpDrop(pct: 45))], realArrivalPct: 41,
                                                        realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertFalse(higher.passed)
        let many = V09Replay.verdict(V09Replay.Result(said: [line(.sharpDrop(pct: 50)), line(.sharpDrop(pct: 45)), line(.arrivingLow(pct: 15))],
                                                      realArrivalPct: 15, realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertFalse(many.passed, "3 battery lines")
        let far = V09Replay.verdict(V09Replay.Result(said: [line(.sharpDrop(pct: 40))], realArrivalPct: 52, realArrivalS: nil, problems: []),
                                    routeKm: 10)
        XCTAssertFalse(far.passed, "12 points off")
        let early = V09Replay.verdict(V09Replay.Result(said: [line(.runningLate(minutes: 5, arriveAt: "9:02"), along: 2)], realArrivalPct: nil,
                                                       realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertFalse(early.passed, "a late line at km 2")
        let fine = V09Replay.verdict(V09Replay.Result(said: [line(.sharpDrop(pct: 45)), line(.sharpDrop(pct: 40))], realArrivalPct: 41,
                                                      realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertTrue(fine.passed, fine.problems.joined(separator: ", "))
    }

    func testLineLogAndSummaryLines() throws {
        var n = V09Numbers()
        n.t = 1_000
        n.arrivalPct = 42.3
        n.arriveAtS = 86_400 + 9 * 3_600 + 2 * 60
        let drop = V09SaidLine(.sharpDrop(pct: 40), numbers: n)
        let late = V09SaidLine(.runningLate(minutes: 6, arriveAt: "9:02"), numbers: n)
        let data = try JSONEncoder().encode([drop, late])
        XCTAssertEqual(try JSONDecoder().decode([V09SaidLine].self, from: data), [drop, late])
        let lines = V09SaidCompare.lines([drop, late], realArrivalPct: 43, realArrivalS: 86_400 + 9 * 3_600 + 5 * 60, utcOffsetMin: 0)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Voice: \u{201C}Arrival battery now about forty percent.\u{201D} \u{00B7} real 43% (3 off)")
        XCTAssertEqual(lines[1], "Voice: \u{201C}Running six minutes late, arriving at 9:02.\u{201D} \u{00B7} real arrival 9:05 (3 min later)")
    }
}
