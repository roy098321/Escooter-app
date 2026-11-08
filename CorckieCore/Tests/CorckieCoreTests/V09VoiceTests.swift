import XCTest
@testable import CorckieCore

/// V09 voice energy updates: the lines, urgent vs can-wait timing, engine temperature with hold / once / re-arm, the arrival line.
final class V09VoiceTests: XCTestCase {
    func testTheLines() {
        XCTAssertEqual(V09Message.arrived(place: "Uni", pct: 58).line, "Arrived at Uni, battery at fifty eight percent.")
        XCTAssertEqual(V09Message.arrived(place: nil, pct: 41).line, "Arrived, battery at forty one percent.")
        XCTAssertEqual(V09Message.engineHot(c: 86).line, "Engine hot, eighty six degrees.")
        XCTAssertEqual(V09Message.runningLate(minutes: 6, arriveAt: "9:02").line, "Running six minutes late, arriving at 9:02.")
        XCTAssertEqual(V09Message.sharpDrop(pct: 40).line, "Arrival battery now about forty percent.")
        XCTAssertEqual(V09Message.backOnTrack(pct: 50).line, "Back on track, about fifty percent.")
        XCTAssertEqual(V09Message.round5(42.4), 40)
        XCTAssertEqual(V09Message.round5(42.6), 45)
        XCTAssertEqual(V09Message.pointOfNoReturn(metres: 300).line, "Point of no return in three hundred metres.")
        XCTAssertEqual(V09Message.usingMore(pctPerKm: 2.6, aboveUsualPct: 15).line, "Using two point six percent per kilometre, fifteen percent above usual.")
        XCTAssertTrue(V09Message.engineOverheating(c: 94).urgent)
        XCTAssertFalse(V09Message.runningLate(minutes: 8, arriveAt: "9:02").urgent)
        XCTAssertEqual(V09Message.samples.count, 18)   // + V-U1 Level 2 (batch 3)
    }

    func testEngineTemperatureHoldsOnceAndReArms() {
        var e = EngineTempTracker()
        XCTAssertNil(e.update(tempC: 88, at: 0))
        XCTAssertNil(e.update(tempC: 60, at: 5), "a one-reading spike does not count")
        XCTAssertNil(e.update(tempC: 86, at: 10))
        XCTAssertNil(e.update(tempC: 86, at: 20))
        XCTAssertEqual(e.update(tempC: 86, at: 30), .engineHot(c: 86), "held 20 s")
        XCTAssertNil(e.update(tempC: 87, at: 60), "once")
        XCTAssertNil(e.update(tempC: 84, at: 70))
        XCTAssertNil(e.update(tempC: 86, at: 100), "hovering around 85 does not repeat")
        XCTAssertNil(e.update(tempC: 74, at: 700), "cooled 10 below and 10 min later: armed again")
        XCTAssertNil(e.update(tempC: 86, at: 710))
        XCTAssertEqual(e.update(tempC: 86, at: 731), .engineHot(c: 86))
        var o = EngineTempTracker()
        _ = o.update(tempC: 94, at: 0)
        XCTAssertEqual(o.update(tempC: 94, at: 21), .engineOverheating(c: 94))
        XCTAssertNil(o.update(tempC: 94, at: 60), "overheating covers hot")
    }

    func testEveryTenIsUrgentAndStartsBelowTheStart() {
        var d = V09Director()
        XCTAssertEqual(d.update(V09Input(t: 0, pct: 87, rideKm: 0, speedKmh: 25)), [])
        XCTAssertEqual(d.update(V09Input(t: 60, pct: 80, rideKm: 1, speedKmh: 25)), [.everyTen(pct: 80)])
        XCTAssertEqual(d.update(V09Input(t: 70, pct: 79, rideKm: 1.1, speedKmh: 25)), [])
        XCTAssertEqual(d.update(V09Input(t: 80, pct: 69, rideKm: 1.2, speedKmh: 25)), [.everyTen(pct: 70)])
    }

    func testCanWaitWaitsForAStop() {
        var d = V09Director()
        _ = d.update(V09Input(t: 0, pct: 90, rideKm: 0, speedKmh: 30, usualPctPerKm: 2))
        // 3 km with 9 % used = 3 %/km, 50 % above usual; riding, turning: it waits
        let moving = d.update(V09Input(t: 300, pct: 81, rideKm: 3, speedKmh: 30, courseDeg: 0, usualPctPerKm: 2))
        XCTAssertFalse(moving.contains { if case .usingMore = $0 { return true } else { return false } })
        XCTAssertEqual(d.waitingCount, 1)
        let stopped = d.update(V09Input(t: 330, pct: 81, rideKm: 3.2, speedKmh: 0, usualPctPerKm: 2))
        XCTAssertTrue(stopped.contains { if case .usingMore = $0 { return true } else { return false } }, "said at the stop")
    }

    func testTiming() {
        XCTAssertEqual(V09Timing.moment(queuedAt: 0, queuedKm: 0, now: 10, rideKm: 0.1, speedKmh: 1, steadyStraight: false, usualStopAheadM: nil), .stopped)
        XCTAssertNil(V09Timing.moment(queuedAt: 0, queuedKm: 0, now: 10, rideKm: 0.1, speedKmh: 30, steadyStraight: true, usualStopAheadM: 600),
                     "a usual stop is 600 m ahead: wait for it")
        XCTAssertEqual(V09Timing.moment(queuedAt: 0, queuedKm: 0, now: 10, rideKm: 0.1, speedKmh: 30, steadyStraight: true, usualStopAheadM: nil), .steadyStraight)
        XCTAssertEqual(V09Timing.moment(queuedAt: 0, queuedKm: 0, now: 121, rideKm: 0.5, speedKmh: 30, steadyStraight: false, usualStopAheadM: 600), .waitedLongEnough)
        XCTAssertTrue(V09Timing.steadyStraight(speeds: [30, 31, 30, 29, 30], courses: [355, 358, 2, 5, 359]))
        XCTAssertFalse(V09Timing.steadyStraight(speeds: [30, 31, 30, 29, 30], courses: [0, 20, 40, 60, 80]))
    }

    func testPointOfNoReturnAndArrival() {
        // 40 %, 2 km along, 3 %/km, reserve 5: (40 + 6 − 5) / 6 ≈ 6.83 km
        XCTAssertEqual(V09Director.pointOfNoReturnKm(pct: 40, alongKm: 2, ratePctPerKm: 3, reservePct: 5) ?? 0, 6.833, accuracy: 0.01)
        // no route history: this ride's rate, only from 3 km (40 % after 3 km from 46 = 2 %/km, 9 km left)
        XCTAssertEqual(V09Director.arrivalPct(level: 40, startPct: 46, rideKm: 3, routeKm: 12, alongKm: 3, history: nil) ?? 0, 22, accuracy: 1e-9)
        XCTAssertNil(V09Director.arrivalPct(level: 42, startPct: 46, rideKm: 2, routeKm: 12, alongKm: 2, history: nil))
        var a = ArrivalLineTracker()
        XCTAssertEqual(a.arrived(place: "Uni", pct: 57.6), .arrived(place: "Uni", pct: 58))
        XCTAssertNil(a.arrived(place: "Uni", pct: 57), "once per arrival")
        XCTAssertNil(a.rideEnded(pct: 55), "no second line at the end")
        var b = ArrivalLineTracker()
        XCTAssertEqual(b.rideEnded(pct: 41), .arrived(place: nil, pct: 41))
    }
}
