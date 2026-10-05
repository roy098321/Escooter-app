import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M2-06 / M2-08: arrival strip (M28), the display throttle (T83), Where to? chips and the dot that keeps moving without GPS (P3 D2).
/// Made-up map only (`SyntheticRoutes`).
final class RouteProgressTests: XCTestCase {
    typealias XY = SyntheticRoutes.XY

    private func geo(_ p: XY) -> GeoPoint {
        let c = SyntheticRoutes.coordinate(p)
        return GeoPoint(lat: c.lat, lon: c.lon)
    }

    private var path: [GeoPoint] { Geo.resample(SyntheticRoutes.main.map { geo($0) }, stepM: 10) }

    private func follower(todayS: Double = 540) throws -> RouteFollower {
        try XCTUnwrap(RouteFollower(destinationName: "Work", path: path, todayS: todayS))
    }

    private func at(_ along: Double) -> GeoPoint { geo(SyntheticRoutes.point(on: SyntheticRoutes.main, at: along)) }

    // MARK: M28

    func test_onPace_remainingIsTheRestOfToday() throws {
        var f = try follower()
        let total = f.totalM
        _ = f.update(position: at(0), gpsFresh: true, rideDistanceM: 0, elapsedS: 0)
        // half way, exactly on pace
        let half = total / 2
        let s = f.update(position: at(half), gpsFresh: true, rideDistanceM: half, elapsedS: 270)
        XCTAssertFalse(s.offPath)
        XCTAssertEqual(s.alongM, half, accuracy: 15)
        XCTAssertEqual(s.remainingS, 270, accuracy: 12)
    }

    func test_runningLate_remainingGrowsButIsBlended() throws {
        var f = try follower()
        _ = f.update(position: at(0), gpsFresh: true, rideDistanceM: 0, elapsedS: 0)
        let d = 2_000.0
        // 2 km done in 1.5x the expected time: weight 2 / (2 + 2) = 0.5
        let expected = d / f.totalM * 540
        let s = f.update(position: at(d), gpsFresh: true, rideDistanceM: d, elapsedS: expected * 1.5)
        let base = (f.totalM - d) / f.totalM * 540
        XCTAssertGreaterThan(s.remainingS, base * 1.15)
        XCTAssertLessThan(s.remainingS, base * 1.5)
        XCTAssertEqual(s.remainingS, base * 1.25, accuracy: base * 0.04)
    }

    func test_firstKm_paceBarelyMoves() throws {
        var f = try follower()
        _ = f.update(position: at(0), gpsFresh: true, rideDistanceM: 0, elapsedS: 0)
        let d = 300.0
        let expected = d / f.totalM * 540
        let s = f.update(position: at(d), gpsFresh: true, rideDistanceM: d, elapsedS: expected * 2)
        let base = (f.totalM - d) / f.totalM * 540
        // km done 0.3 -> weight 0.13: at most 13% more than the base
        XCTAssertLessThan(s.remainingS, base * 1.14)
    }

    func test_offRoute_usesStraightDistanceOverTypicalSpeed() throws {
        var f = try follower()
        _ = f.update(position: at(1_000), gpsFresh: true, rideDistanceM: 1_000, elapsedS: 150)
        let away = geo((x: 5_000, y: 1_000))
        let s = f.update(position: away, gpsFresh: true, rideDistanceM: 1_100, elapsedS: 170)
        XCTAssertTrue(s.offPath)
        let end = path[path.count - 1]
        XCTAssertEqual(s.remainingS, Geo.distanceM(away, end) / f.typicalSpeedMps, accuracy: 0.5)
    }

    func test_backOnRoute_isFollowedAgain() throws {
        var f = try follower()
        _ = f.update(position: at(1_000), gpsFresh: true, rideDistanceM: 1_000, elapsedS: 150)
        _ = f.update(position: geo((x: 5_000, y: 1_000)), gpsFresh: true, rideDistanceM: 1_100, elapsedS: 170)
        let s = f.update(position: at(1_500), gpsFresh: true, rideDistanceM: 1_600, elapsedS: 230)
        XCTAssertFalse(s.offPath)
        XCTAssertEqual(s.alongM, 1_500, accuracy: 15)
    }

    func test_tooShortOrEmptyPath_noFollower() {
        XCTAssertNil(RouteFollower(destinationName: "x", path: [], todayS: 300))
        XCTAssertNil(RouteFollower(destinationName: "x", path: [GeoPoint(lat: 10, lon: -30), GeoPoint(lat: 10.0002, lon: -30)], todayS: 300))
        XCTAssertNil(RouteFollower(destinationName: "x", path: path, todayS: 0))
    }

    // MARK: T83

    func test_display_changesEvery30sOrOnAMinuteJump() {
        var d = ArrivalDisplay()
        let first = d.show(remainingS: 600, nowS: 1_000)                    // arrival 1600
        XCTAssertEqual(first, 1_600)
        XCTAssertEqual(d.show(remainingS: 590, nowS: 1_010), 1_600, "10 s later, 10 s earlier: unchanged")
        XCTAssertEqual(d.show(remainingS: 580, nowS: 1_020), 1_600, "still inside 30 s and under a minute")
        XCTAssertEqual(d.show(remainingS: 500, nowS: 1_025), 1_525, "a jump of a minute or more shows at once")
        XCTAssertEqual(d.show(remainingS: 520, nowS: 1_060), 1_580, "30 s passed: refreshed")
    }

    func test_stripText() {
        // 2026-10-05 05:56 UTC, +3 h -> 8:56
        let arrival = 1_790_000_000.0 - (1_790_000_000.0.truncatingRemainder(dividingBy: 86_400)) + 5 * 3_600 + 56 * 60
        let text = ArrivalStrip.text(destination: "Work", arrivalS: arrival, nowS: arrival - 9 * 60, utcOffsetMin: 180)
        XCTAssertEqual(text, "Work \u{00B7} arrive ~8:56 \u{00B7} 9 min left")
    }

    // MARK: Where to?

    func test_whereTo_hiddenWithoutRides_andLabelsFromThePlace() {
        let now: Int64 = 20_717 * 86_400_000 + 8 * 3_600_000
        XCTAssertTrue(WhereTo.chips([WhereToInput(routeId: "r", title: "Route 1", toName: "Work", rides: [])], nowMs: now, utcOffsetMin: 0).isEmpty)
        let rides = (0..<5).map { i in
            RouteRideStats(rideId: "r\(i)", startAt: (20_717 - Int64(i + 1)) * 86_400_000 + 8 * 3_600_000, totalS: 720, distanceM: 3_700,
                           avgMovingMps: 7, usedPct: 10)
        }
        let chips = WhereTo.chips([WhereToInput(routeId: "r", title: "Route 1", toName: "Work", rides: rides),
                                   WhereToInput(routeId: "q", title: "Route 2", toName: nil, rides: rides)], nowMs: now, utcOffsetMin: 0)
        XCTAssertEqual(chips.map(\.label), ["Work", "Route 2"])
        XCTAssertTrue(chips[0].detail.contains("today ~12 min"), chips[0].detail)
        XCTAssertTrue(chips[0].detail.contains("arrive ~8:12"), chips[0].detail)
        XCTAssertTrue(chips[0].detail.contains("uses about 10%"), "honest number, no margin: \(chips[0].detail)")
        let few = WhereTo.chips([WhereToInput(routeId: "r", title: "Route 1", toName: "Work", rides: Array(rides.prefix(2)))], nowMs: now, utcOffsetMin: 0)
        XCTAssertTrue(few[0].detail.contains("2 of 3 rides"), few[0].detail)
    }

    // MARK: M2-08 dead reckoning

    func test_gpsLost_dotMovesByWheelDistance() throws {
        var f = try follower()
        _ = f.update(position: at(500), gpsFresh: true, rideDistanceM: 500, elapsedS: 80)
        let s = f.update(position: at(500), gpsFresh: false, rideDistanceM: 2_500, elapsedS: 360)
        XCTAssertTrue(s.deadReckoned)
        XCTAssertEqual(s.alongM, 2_500, accuracy: 0.5)
        let dot = try XCTUnwrap(s.dot)
        XCTAssertLessThan(Geo.distanceM(dot, at(2_500)), 5, "the dot is on the route")
        // the arrival strip keeps updating
        XCTAssertLessThan(s.remainingS, (f.totalM - 2_000) / f.totalM * 540 * 1.1)
    }

    func test_gpsLost_offRoute_orNoRoute_dotStaysFrozen() throws {
        var f = try follower()
        _ = f.update(position: geo((x: 5_000, y: 0)), gpsFresh: true, rideDistanceM: 100, elapsedS: 20)
        let s = f.update(position: geo((x: 5_000, y: 0)), gpsFresh: false, rideDistanceM: 900, elapsedS: 150)
        XCTAssertFalse(s.deadReckoned)
        XCTAssertNil(s.dot)
        // never on the route yet: nothing to move along
        var g = try follower()
        let n = g.update(position: nil, gpsFresh: false, rideDistanceM: 300, elapsedS: 40)
        XCTAssertFalse(n.deadReckoned)
    }

    func test_gpsBack_dotSnapsToTheFix() throws {
        var f = try follower()
        _ = f.update(position: at(500), gpsFresh: true, rideDistanceM: 500, elapsedS: 80)
        _ = f.update(position: at(500), gpsFresh: false, rideDistanceM: 1_200, elapsedS: 180)
        let s = f.update(position: at(1_300), gpsFresh: true, rideDistanceM: 1_300, elapsedS: 190)
        XCTAssertFalse(s.deadReckoned)
        XCTAssertEqual(s.alongM, 1_300, accuracy: 15)
    }

    func test_driver_hollowDotAndArrivalStrip() throws {
        var d = LiveScreenDriver()
        d.follow(try follower(), utcOffsetMin: 0)
        func input(_ along: Double, fresh: Bool, wheel: Double, lastAlong: Double) -> LiveInput {
            let p = at(lastAlong)
            return LiveInput(scooterSpeedKmh: 25, scooterBatteryPct: 80, secondsWithoutGps: fresh ? 0 : 20, phase: .riding,
                             lat: p.lat, lon: p.lon, rideElapsedS: along / 6.9, rideDistanceM: wheel)
        }
        let a = d.update(input(500, fresh: true, wheel: 500, lastAlong: 500), at: 1_000)
        XCTAssertNotNil(a.arrival)
        XCTAssertFalse(a.dotHollow)
        let b = d.update(input(1_500, fresh: false, wheel: 1_500, lastAlong: 500), at: 1_145)
        XCTAssertTrue(b.dotHollow)
        XCTAssertFalse(b.dotGreyed)
        XCTAssertTrue(b.chips.contains(.noGps) || b.banner?.banner == .noGps)
        let dot = try XCTUnwrap(b.dotOverride)
        XCTAssertLessThan(Geo.distanceM(GeoPoint(lat: dot.lat, lon: dot.lon), at(1_500)), 5)
        XCTAssertTrue(b.arrival?.deadReckoned == true)
    }

    func test_driver_withoutARoute_keepsTheGreyFrozenDot() {
        var d = LiveScreenDriver()
        let s = d.update(LiveInput(scooterSpeedKmh: 25, secondsWithoutGps: 20, phase: .riding, lat: 10, lon: -30, rideDistanceM: 900), at: 5)
        XCTAssertNil(s.arrival)
        XCTAssertNil(s.dotOverride)
        XCTAssertTrue(s.dotGreyed)
    }

    // MARK: ROUTE-GPSLOSS (whole engine)

    func test_scenario_gpsLoss_dotWithin30mAfter2km() throws {
        let leg = SyntheticRoutes.trip(path: SyntheticRoutes.main, cruiseKmh: 25, seed: 10)
        let lossy = leg.stream.applying([.gpsLoss(from: 90, to: 400)])
        let run = EngineRunner.run(lossy, tailS: 60, collectLive: true)
        var d = LiveScreenDriver()
        d.follow(try follower(todayS: 540), utcOffsetMin: 0)
        let truth = leg.stream.phone.compactMap { $0.fix }
        var worst = 0.0
        var checked = 0
        var movedHollow = false
        var first: Double?
        for item in run.live where item.input.phase == .riding {
            let s = d.update(item.input, at: item.t)
            guard item.t >= 90, item.t <= 400, let dot = s.dotOverride, s.dotHollow else { continue }
            movedHollow = true
            if first == nil { first = item.t }
            guard let real = truth.min(by: { abs($0.t - item.t) < abs($1.t - item.t) }) else { continue }
            let off = Geo.distanceM(GeoPoint(lat: dot.lat, lon: dot.lon), GeoPoint(lat: real.lat, lon: real.lon))
            // 2 km after the loss started
            if item.input.rideDistanceM ?? 0 > 2_620 { worst = max(worst, off); checked += 1 }
        }
        XCTAssertTrue(movedHollow, "the dot moved hollow while GPS was lost")
        XCTAssertGreaterThan(checked, 5, "the ride got more than 2 km into the loss")
        XCTAssertLessThan(worst, 30, "dot within 30 m of the real path after 2 km without GPS")
    }
}
