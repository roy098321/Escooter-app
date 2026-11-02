import XCTest
@testable import CorckieCore

/// Hotfix 03 H1 / H2 (B69 / B70): the voice on made-up rides of a made-up 10 km route with 3 past rides (2 %/km, 24 min).
final class Hotfix03VoiceTests: XCTestCase {
    /// Runs the director over a ride once a second, like the app: (line, numbers behind it)
    private func run(_ ride: [RouteHistorySample], history: RouteHistory? = H3Fix.history(), todayS: Double = 1_440,
                     placeName: String? = nil) -> [(m: V09Message, n: V09Numbers)] {
        var d = V09Director()
        var f = H3Fix.follower(todayS: todayS, history: history)
        var out: [(m: V09Message, n: V09Numbers)] = []
        var metres = 0.0
        var last: Double?
        var t0: Double?
        for p in ride {
            if let l = last { metres += (p.speedKmh ?? 0) / 3.6 * (p.t - l) }
            last = p.t
            if t0 == nil, (p.speedKmh ?? 0) > 3 { t0 = p.t }
            let elapsed = t0.map { p.t - $0 } ?? 0
            let step = f.update(position: GeoPoint(lat: p.lat!, lon: -30), gpsFresh: true, rideDistanceM: metres, elapsedS: elapsed)
            let i = V09Input(t: p.t, pct: p.batteryPct, rideKm: metres / 1000, speedKmh: p.speedKmh, courseDeg: 0, routeKm: f.totalM / 1000,
                             alongKm: step.alongM / 1000, elapsedS: elapsed, remainingS: step.remainingS, powerW: p.powerW,
                             currentA: p.currentA, whPerPct: 8.1, history: history, todayS: todayS, placeName: placeName)
            for m in d.update(i) { out.append((m, d.numbers)) }
        }
        return out
    }

    private func batteryLines(_ said: [(m: V09Message, n: V09Numbers)]) -> [V09Message] {
        said.map { $0.m }.filter { ["drop", "low", "back"].contains($0.kind) }
    }

    // MARK: H1

    func testHillSagSaysNothing() {
        // full throttle up a hill at km 4: the scooter's % reads 8 points low for 40 s, then comes back
        let said = run(H3Fix.ride(sag: { _, km in km >= 4 && km < 4.28 ? 8 : 0 }))
        XCTAssertEqual(batteryLines(said), [], said.map { $0.m.line }.joined(separator: " | "))
        let tens = said.compactMap { if case let .everyTen(p) = $0.m { return p } else { return nil } }
        XCTAssertEqual(tens.first, 80)
        XCTAssertEqual(Set(tens).count, tens.count, "each step once")
    }

    func testHillSagWithoutPowerReadingsSaysNothingEither() {
        let said = run(H3Fix.ride(sag: { _, km in km >= 4 && km < 4.28 ? 8 : 0 }, withPower: false))
        XCTAssertEqual(batteryLines(said), [], said.map { $0.m.line }.joined(separator: " | "))
    }

    func testARealDrainSaysOneLine() {
        // from km 3 the ride really uses 3.2 %/km instead of 2: the arrival estimate slides from 70 to ~62 = one line, about 65
        let said = run(H3Fix.ride(pctPerKm: { $0 < 3 ? 2 : 3.2 }))
        let lines = batteryLines(said)
        XCTAssertEqual(lines, [.sharpDrop(pct: 65)], said.map { $0.m.line }.joined(separator: " | "))
        let n = said.first { $0.m.kind == "drop" }?.n
        XCTAssertEqual(n?.stable, true)
        XCTAssertGreaterThanOrEqual(n?.rideKm ?? 0, 2)
    }

    func testABetterEstimateNeverGivesAHigherNumber() {
        // heavy, then easy (the estimate gets better by 3 points: silent), then heavy again
        let said = run(H3Fix.ride(pctPerKm: { km in km < 3 ? 2 : km < 5 ? 5 : km < 7 ? 0.5 : 5 }))
        let values = batteryLines(said).compactMap(\.value)
        XCTAssertFalse(values.isEmpty)
        XCTAssertLessThanOrEqual(values.count, 2)
        for k in values.indices.dropFirst() { XCTAssertLessThan(values[k], values[k - 1], "\(values)") }
        XCTAssertFalse(batteryLines(said).contains { $0.kind == "back" })
    }

    func testNothingInTheFirstTwoKm() {
        // a very heavy start: no battery line before 2 km
        let said = run(H3Fix.ride(pctPerKm: { $0 < 2.5 ? 8 : 2 }))
        for s in said where ["drop", "low", "back"].contains(s.m.kind) { XCTAssertGreaterThanOrEqual(s.n.rideKm, 2) }
    }

    func testNoHistoryIsSilentUntilThreeKm() {
        let said = run(H3Fix.ride(pctPerKm: { $0 < 3 ? 6 : 2 }), history: nil)
        for s in said where ["drop", "low", "back"].contains(s.m.kind) { XCTAssertGreaterThanOrEqual(s.n.rideKm, 3) }
    }

    // MARK: H2

    func testAnEarlyRedLightIsNotLate() {
        let said = run(H3Fix.ride(stops: [(atM: 1_000, s: 60)]))
        XCTAssertFalse(said.contains { $0.m.kind == "late" }, said.map { $0.m.line }.joined(separator: " | "))
    }

    func testReallyLateSaysOneLineAfterTheGate() throws {
        // from km 2 the ride crawls at 17 km/h: 5 minutes behind today's estimate at about km 6.4
        let said = run(H3Fix.ride(slowFrom: 2, slowKmh: 17))
        let late = said.filter { $0.m.kind == "late" }
        XCTAssertEqual(late.count, 1, said.map { $0.m.line }.joined(separator: " | "))
        let first = try XCTUnwrap(late.first)
        XCTAssertEqual(first.m.value, 5)
        XCTAssertTrue(first.m.line.hasPrefix("Running five minutes late, arriving at "), first.m.line)
        XCTAssertGreaterThanOrEqual(first.n.alongKm ?? 0, max(V09Director.lateAfterKm, 10.0 / 3))
    }

    func testLateIsAgainstTodaysEstimateNotTheUsualTime() {
        // today's estimate is 30 min (slower than the usual 24 min, e.g. a headwind); riding as estimated is not late
        let said = run(H3Fix.ride(speedKmh: 20), todayS: 1_800)
        XCTAssertFalse(said.contains { $0.m.kind == "late" })
    }

    // MARK: H3

    func testStartLineOnceOnAKnownRoute() {
        let said = run(H3Fix.ride(), placeName: "Uni")
        let starts = said.filter { $0.m.kind == "start" }
        XCTAssertEqual(starts.count, 1)
        // set off at 1 000 010 s (UTC), 24 min estimate: arriving 14:10; rested start 90 %
        XCTAssertEqual(starts.first?.m.line, "Riding to Uni, arriving at 14:10, battery at ninety percent.")
        XCTAssertEqual(said.first?.m.kind, "start", "the first thing said")
        XCTAssertFalse(run(H3Fix.ride()).contains { $0.m.kind == "start" }, "no destination name: no start line")
    }

    func testTheShortDestinationLineKnowsItIsTheStart() {
        var a = DestinationAnnouncer()
        XCTAssertFalse(a.update(riding: true, key: "r", at: 0))
        XCTAssertTrue(a.update(riding: true, key: "r", at: 5))
        XCTAssertTrue(a.lastWasStart)
        XCTAssertTrue(a.update(riding: true, key: "q", at: 60))
        XCTAssertFalse(a.lastWasStart, "a change during the ride is not the start")
    }
}
