import XCTest
@testable import CorckieCore

/// F-34: the shared energy track: power shape per ~100 m, scaled to the battery drop; battery-only fallback; gaps stay gaps.
final class EnergyTrackTests: XCTestCase {
    /// A made-up straight ride: one reading per second at 18 km/h (5 m/s), heading north (not a real place)
    private func ride(_ n: Int, power: (Int) -> Double?, battery: (Int) -> Int?) -> [SeriesPoint] {
        (0..<n).map { i in
            SeriesPoint(t: Double(i), lat: 10.0 + Double(i) * 5 / Geo.mPerDegLat, lon: 20.0, hAccM: 5, speedKmh: 18,
                        batteryPct: battery(i), powerW: power(i))
        }
    }

    func testPowerShapeIsScaledToTheBatteryDrop() {
        // 600 s at 5 m/s = 3 km; first half 200 W, second half 600 W; battery 80 -> 70
        let pts = ride(601, power: { $0 < 300 ? 200 : 600 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 })
        let track = EnergyTrack.build(pts)
        XCTAssertEqual(track.source, .power)
        XCTAssertEqual(track.totalUsedPct, 10, accuracy: 0.001)
        XCTAssertEqual(track.bins.compactMap(\.usedPct).reduce(0, +), 10, accuracy: 0.01)
        XCTAssertEqual(Double(track.bins.count), 30, accuracy: 1.5)
        // the shape: a stretch in the second half costs about three times one in the first
        let early = track.bins[5].usedPct ?? 0, late = track.bins[25].usedPct ?? 0
        XCTAssertEqual(late / early, 3, accuracy: 0.2)
        XCTAssertEqual(track.bins[25].pctPerKm ?? 0, late / track.bins[25].lengthKm, accuracy: 0.001)
    }

    func testAStoredDropWins() {
        let pts = ride(301, power: { _ in 300 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 })
        let track = EnergyTrack.build(pts, totalUsedPct: 7)
        XCTAssertEqual(track.bins.compactMap(\.usedPct).reduce(0, +), 7, accuracy: 0.01)
    }

    func testNoPowerFallsBackToTheBatteryReadings() {
        let pts = ride(601, power: { _ in nil }, battery: { $0 >= 590 ? 74 : 80 - $0 / 100 })
        let track = EnergyTrack.build(pts)
        XCTAssertEqual(track.source, .battery)
        XCTAssertEqual(track.bins.compactMap(\.usedPct).reduce(0, +), 6, accuracy: 0.01)
        XCTAssertTrue(track.bins.allSatisfy { ($0.usedPct ?? 0) >= 0 })
    }

    func testPhoneTakeoverIsAGap() {
        // 200 s without power in the middle (the phone took over), power everywhere else
        let pts = ride(601, power: { (200..<400).contains($0) ? nil : 300 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 })
        let track = EnergyTrack.build(pts)
        XCTAssertEqual(track.source, .power)
        XCTAssertTrue(track.bins.contains { $0.usedPct == nil }, "the takeover stretch is a gap")
        XCTAssertNil(track.bin(at: 300)?.usedPct)
        XCTAssertEqual(track.bins.compactMap(\.usedPct).reduce(0, +), 10, accuracy: 0.01)
    }

    func testUsedBetweenTwoTimes() {
        let pts = ride(601, power: { _ in 300 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 })
        let track = EnergyTrack.build(pts)
        XCTAssertEqual(track.usedPct(from: 0, to: 600) ?? 0, 10, accuracy: 0.05)
        XCTAssertEqual(track.usedPct(from: 0, to: 300) ?? 0, 5, accuracy: 0.3)
        XCTAssertNil(track.usedPct(from: 10, to: 5))
    }

    func testNothingToGoOn() {
        XCTAssertEqual(EnergyTrack.build([]).source, .none)
        let pts = ride(100, power: { _ in nil }, battery: { _ in nil })
        XCTAssertEqual(EnergyTrack.build(pts).source, .none)
    }

    func testClimbCostComesFromTheTrack() {
        // flat 100 s, a 150 s climb (+30 m) on more power, flat again; battery 80 -> 72
        var pts = ride(401, power: { (100..<250).contains($0) ? 800 : 200 }, battery: { $0 >= 390 ? 72 : 80 - $0 / 50 })
        for i in pts.indices { pts[i].altM = i < 100 ? 10 : (i < 250 ? 10 + Double(i - 100) * 0.2 : 40) }
        let track = EnergyTrack.build(pts)
        let climbs = RideLayers.elevation(pts, energy: track).climbs
        XCTAssertEqual(climbs.count, 1)
        // the climb took most of the energy: 150 s × 800 W of (150 × 800 + 250 × 200) Wh-shape, of 8 % ≈ 5.6 %
        XCTAssertEqual(Double(climbs.first?.usedPct ?? 0), 5.6, accuracy: 1.1)
    }
}
