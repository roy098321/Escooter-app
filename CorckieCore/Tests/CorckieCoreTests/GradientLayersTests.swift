import XCTest
@testable import CorckieCore

/// F-04: continuous colour ramps with fixed scales, per-stretch values, ~10 s smoothing.
final class GradientLayersTests: XCTestCase {
    func testRampEndsAndMiddle() {
        let r = LayerRamps.hills(colourBlind: false)
        XCTAssertEqual(r.lo, -8)
        XCTAssertEqual(r.hi, 8)
        let flat = r.rgb(at: 0)
        XCTAssertEqual(flat.r, 0x9E / 255.0, accuracy: 0.001)       // flat = neutral grey
        let low = r.rgb(at: -50), high = r.rgb(at: 50)               // clamped to the ends
        XCTAssertEqual(low.b, 0xE5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(high.r, 0xF2 / 255.0, accuracy: 0.001)
    }

    func testSpeedRampIsContinuousAndFixed() {
        let r = LayerRamps.speed(colourBlind: false)
        XCTAssertEqual(r.lo, 0)
        XCTAssertEqual(r.hi, 50)
        // neighbouring values give neighbouring colours (no steps), and a value above 50 equals 50
        var last = r.rgb(at: 0)
        for v in stride(from: 1.0, through: 50.0, by: 1.0) {
            let c = r.rgb(at: v)
            XCTAssertLessThan(abs(c.r - last.r) + abs(c.g - last.g) + abs(c.b - last.b), 0.2)
            last = c
        }
        XCTAssertEqual(r.rgb(at: 80).r, r.rgb(at: 50).r)
    }

    func testColourBlindRampsDifferAndAreContinuous() {
        for layer in MapLayer.allCases {
            let normal = LayerRamps.ramp(layer, colourBlind: false)
            let safe = LayerRamps.ramp(layer, colourBlind: true)
            XCTAssertEqual(normal.lo, safe.lo)
            XCTAssertEqual(normal.hi, safe.hi)
            XCTAssertNotEqual(normal.hex, safe.hex)
        }
        XCTAssertEqual(LayerRamps.speed(colourBlind: true).hex.count, 6)
    }

    func testSmoothingAveragesAboutTenSeconds() {
        let a = GeoPoint(lat: 1, lon: 1)
        // 1 stretch per second, alternating 0 / 40 km/h: the smoothed value sits near 20
        let raw = (0..<30).map { ValueStretch(a: a, b: a, t: Double($0), value: $0 % 2 == 0 ? 0 : 40) }
        let s = RideLayers.smoothedStretches(raw, windowS: 10)
        XCTAssertEqual(s.count, raw.count)
        for i in 6..<24 { XCTAssertEqual(s[i].value, 20, accuracy: 4) }
        // a single stretch is left alone
        XCTAssertEqual(RideLayers.smoothedStretches([raw[0]]).first?.value, 0)
    }

    private func line(_ n: Int, alt: (Int) -> Double, speed: (Int) -> Double) -> [SeriesPoint] {
        (0..<n).map { i in
            SeriesPoint(t: Double(i) * 5, lat: 10.0 + Double(i) * 0.000_2, lon: 20.0, hAccM: 5, speedKmh: speed(i), batteryPct: 80, altM: alt(i))
        }
    }

    func testSpeedAndHillStretches() {
        let pts = line(40, alt: { 50 + Double($0) * 2 }, speed: { Double($0) })   // 9% up, speeding up
        let speeds = RideLayers.speedStretches(pts)
        XCTAssertFalse(speeds.isEmpty)
        XCTAssertLessThan(speeds.first!.value, speeds.last!.value)
        let hills = RideLayers.hillStretches(pts)
        XCTAssertFalse(hills.isEmpty)
        for h in hills.dropFirst().dropLast() { XCTAssertGreaterThan(h.value, 5) }
        // neighbours share a point: no gap in the line
        for i in 1..<hills.count { XCTAssertEqual(hills[i - 1].b, hills[i].a) }
    }

    func testWindStretchesHeadwindPositiveAndNilWithoutWeather() {
        let start: Int64 = 1_790_000_000_000
        let hour = (start / 3_600_000) * 3_600_000
        let rows = [WeatherRow(cellKey: "c", hourAt: hour, source: "test", kind: .history, windKmh: 20, windFromDeg: 0, fetchedAt: 0),
                    WeatherRow(cellKey: "c", hourAt: hour + 3_600_000, source: "test", kind: .history, windKmh: 20, windFromDeg: 0, fetchedAt: 0)]
        let pts = line(30, alt: { _ in 50 }, speed: { _ in 16 })
        let head = RideLayers.windStretches(pts, rideStartMs: start, rows: rows)
        XCTAssertNotNil(head)
        for s in head ?? [] { XCTAssertEqual(s.value, 20, accuracy: 0.5) }        // riding north into a north wind
        XCTAssertNil(RideLayers.windStretches(pts, rideStartMs: start, rows: []))
    }
}

final class GradientReplayTests: XCTestCase {
    func testReplayPageUsesTheSameRampsContinuously() throws {
        var rows: [ReplayRow] = []
        for t in stride(from: 0, through: 100, by: 5) {
            let s = Double(t)
            rows.append(ReplayRow(t: s, lat: 10 + s * 0.00004, lon: -30 + s * 0.00004, hAccM: 5, speedKmh: 20, gpsKmh: 19, altM: 30,
                                  powerW: 200, batteryPct: 80, tempC: 30))
        }
        let d = try XCTUnwrap(ReplayBuilder.make(title: "Ride", dateLabel: "6 Oct", startAtMs: 1_790_000_000_000, utcOffsetMin: 180, rows: rows,
                                                 stops: [], info: ReplayRideInfo(distanceM: 1_000, startPct: 80, endPct: 79)))
        let plain = ReplayHTML.build(d) { _ in nil }
        XCTAssertTrue(plain.contains("var RAMP = ['#22b24c', '#f2d21b', '#f28c1b', '#e53935'];"))
        XCTAssertTrue(plain.contains("function rampColour"))
        let blind = ReplayHTML.build(d, colourBlind: true) { _ in nil }
        XCTAssertTrue(blind.contains("var RAMP = ['#00204d', '#31446b', '#666970', '#958f78', '#cbba69', '#ffea46'];"))
    }
}
