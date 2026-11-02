import XCTest
@testable import CorckieCore

/// Hotfix 03 base: the sag-proof battery level and the route's past rides point by point (made-up route and rides only).
final class Hotfix03BaseTests: XCTestCase {
    private func levels(_ samples: [RouteHistorySample], whPerPct: Double = 8.1) -> [Double] {
        var b = SagProofBattery()
        return samples.compactMap {
            b.update(t: $0.t, livePct: $0.batteryPct, powerW: $0.powerW, currentA: $0.currentA, speedKmh: $0.speedKmh, whPerPct: whPerPct)
        }
    }

    func testHillSagDoesNotMoveTheLevel() {
        // the scooter's % reads 8 points low for 40 s on a hill at km 4, then comes back
        let ride = H3Fix.ride(sag: { _, km in km >= 4 && km < 4.28 ? 8 : 0 })
        let l = levels(ride)
        XCTAssertEqual(l.count, ride.count)
        for (i, s) in ride.enumerated() {
            let km = (s.lat! - 10) * Geo.mPerDegLat / 1000
            let trueLevel = 90 - 2 * km
            XCTAssertEqual(l[i], trueLevel, accuracy: 1.0, "at km \(km)")
        }
    }

    func testRestedStartIsTheLastReadingBeforeSettingOff() {
        var b = SagProofBattery()
        b.update(t: 0, livePct: 91, powerW: 0, currentA: 0, speedKmh: 0, whPerPct: 8.1)
        b.update(t: 1, livePct: 92, powerW: 0, currentA: 0, speedKmh: 0, whPerPct: 8.1)
        b.update(t: 2, livePct: 85, powerW: 900, currentA: 18, speedKmh: 10, whPerPct: 8.1)
        XCTAssertEqual(b.startPct, 92, "a sagging reading while setting off is not the start")
    }

    func testRestedReadingsNudgeAWrongCalibration() {
        // the true Wh per 1 % is 10, the app thinks 8.1: the level runs low; a 2-minute stop with no current pulls it back towards the %
        let ride = H3Fix.ride(whPerPct: 10, stops: [(atM: 5_000, s: 120)])
        var b = SagProofBattery()
        var atStopEnd: Double?
        var beforeStop: Double?
        for s in ride {
            let l = b.update(t: s.t, livePct: s.batteryPct, powerW: s.powerW, currentA: s.currentA, speedKmh: s.speedKmh, whPerPct: 8.1)
            let km = (s.lat! - 10) * Geo.mPerDegLat / 1000
            if km >= 4.99, km < 5.0, beforeStop == nil { beforeStop = l }
            if km >= 5.0, s.speedKmh == 0, s.t - H3Fix.t0 < 900 { atStopEnd = l }
        }
        let live = 80.0
        XCTAssertLessThan(abs((atStopEnd ?? 0) - live), abs((beforeStop ?? 0) - live), "closer to the rested % after the stop")
    }

    func testNoPowerReadingsUseTheScootersPercent() {
        let ride = H3Fix.ride(withPower: false)
        let l = levels(ride)
        XCTAssertEqual(l.last, ride.last?.batteryPct)
    }

    func testProfileFromEnergyAndFromTheRecoveredPercent() throws {
        let f = H3Fix.follower()
        let energy = try XCTUnwrap(RouteRideProfile.make(samples: H3Fix.ride(stops: [(atM: 2_000, s: 60)]), route: f, whPerPct: 8.1))
        XCTAssertEqual(energy.usedPct(atKm: 10) ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(energy.elapsedS(atKm: 5) ?? 0, 720 + 60, accuracy: 15, "time from setting off, the usual stop inside")
        // no power: the % with a 40 s sag of 8 points at km 6 still gives the true use (the sag is taken out)
        let sagging = H3Fix.ride(sag: { _, km in km >= 6 && km < 6.28 ? 8 : 0 }, withPower: false)
        let pct = try XCTUnwrap(RouteRideProfile.make(samples: sagging, route: f, whPerPct: 8.1))
        XCTAssertEqual(pct.usedPct(atKm: 6.1) ?? 0, 12.2, accuracy: 2.0)
        XCTAssertEqual(pct.usedPct(atKm: 10) ?? 0, 20, accuracy: 1.2)
    }

    func testAPartRideIsNoProfile() {
        let half = H3Fix.ride().filter { ($0.lat! - 10) * Geo.mPerDegLat < 5_000 }
        XCTAssertNil(RouteRideProfile.make(samples: half, route: H3Fix.follower(), whPerPct: 8.1))
    }

    func testHistoryTodayShapeAndShareFaster() {
        let fast = RouteRideProfile(alongKm: [0, 5, 10], elapsedS: [0, 600, 1_200], usedPct: [0, 10, 20])
        let slow = RouteRideProfile(alongKm: [0, 5, 10], elapsedS: [0, 900, 1_500], usedPct: [0, 11, 21])
        let h = RouteHistory(rides: [fast, slow, slow], routeKm: 10)
        XCTAssertEqual(h.usualTotalS ?? 0, 1_500, accuracy: 1e-9)
        XCTAssertEqual(h.usualElapsedS(atKm: 5) ?? 0, 900, accuracy: 1e-9)
        // today's estimate 1 200 s, in the usual shape: 900 / 1 500 of it at km 5
        XCTAssertEqual(h.todayElapsedS(atKm: 5, todayS: 1_200), 720, accuracy: 1e-9)
        XCTAssertEqual(h.todayRemainingS(atKm: 5, todayS: 1_200), 480, accuracy: 1e-9)
        XCTAssertEqual(h.shareFaster(elapsedS: 800, atKm: 5) ?? 0, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(h.shareFaster(elapsedS: 950, atKm: 5) ?? 0, 1, accuracy: 1e-9)
    }
}
