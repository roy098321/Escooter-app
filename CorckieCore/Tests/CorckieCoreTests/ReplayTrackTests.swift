import XCTest
@testable import CorckieCore

/// P6-4: F-18 native Replay track, F-28 chart cursor and zoom, B38 climb battery, B39 map fit. Made-up points only (in the ocean).
final class ReplayTrackTests: XCTestCase {
    /// 61 readings 1 s apart going north, 10 m/s, battery 80 -> 77, power 300 W, climbing 0.5 m/s
    private func points() -> [SeriesPoint] {
        (0...60).map { i in
            SeriesPoint(t: 1_000 + Double(i), lat: 10 + Double(i) * 0.000_09, lon: -30, hAccM: 5, speedKmh: 36,
                        batteryPct: 80 - i / 20, altM: 20 + Double(i) * 0.5, powerW: 300)
        }
    }

    func testTrackStartsAtZeroAndMeasuresDistance() {
        let track = ReplayTrack.build(points())
        XCTAssertEqual(track.samples.first?.t, 0)
        XCTAssertEqual(track.durationS, 60, accuracy: 1e-9)
        XCTAssertEqual(track.samples.last?.distM ?? 0, 600, accuracy: 10)
        XCTAssertEqual(track.samples.last?.altM ?? 0, 30, accuracy: 1e-9)
        XCTAssertTrue(track.has(.power) && track.has(.elevation))
    }

    func testStateBlendsBetweenReadingsAndClamps() throws {
        let track = ReplayTrack.build(points())
        let s = try XCTUnwrap(track.state(atTime: 10.5))
        XCTAssertEqual(s.distM, 105, accuracy: 2)
        XCTAssertEqual(s.lat ?? 0, 10 + 10.5 * 0.000_09, accuracy: 1e-9)
        XCTAssertEqual(s.batteryPct, 80)
        XCTAssertEqual(track.state(atTime: -5)?.t, 0)
        XCTAssertEqual(track.state(atTime: 999)?.t, 60)
        XCTAssertEqual(track.state(atTime: 60)?.batteryPct, 77)
        XCTAssertNil(ReplayTrack.build([]).state(atTime: 1))
    }

    func testDotHoldsTheLastFixThroughAGpsHole() throws {
        var pts = points()
        for i in 20..<30 { pts[i].lat = nil; pts[i].lon = nil }
        let track = ReplayTrack.build(pts)
        let s = try XCTUnwrap(track.state(atTime: 25))
        XCTAssertEqual(s.lat ?? 0, 10 + 19 * 0.000_09, accuracy: 1e-9)
    }

    func testStretchesPerLayer() {
        let track = ReplayTrack.build(points())
        let speed = track.stretches(.speed)
        XCTAssertGreaterThan(speed.count, 20)
        XCTAssertTrue(speed.allSatisfy { abs($0.value - 36) < 1e-9 })
        XCTAssertTrue(track.stretches(.power).allSatisfy { abs($0.value - 300) < 1e-9 })
        let ramp = track.ramp(.elevation, colourBlind: false)
        XCTAssertEqual(ramp.lo, 0)
        XCTAssertEqual(ramp.hi, 30)
    }

    func testMercatorRoundTrip() {
        let m = ReplayBuilder.mercator(lat: 10.123_45, lon: -30.543_21, z: 16)
        let g = ReplayBuilder.degrees(x: m.x, y: m.y, z: 16)
        XCTAssertEqual(g.lat, 10.123_45, accuracy: 1e-9)
        XCTAssertEqual(g.lon, -30.543_21, accuracy: 1e-9)
    }

    func testTrackFromTheReplayTimeline() throws {
        let rows = (0...120).map { i in
            ReplayRow(t: Double(i), lat: 10 + Double(i) * 0.000_05, lon: -30, hAccM: 5, speedKmh: 20, batteryPct: 80 - Double(i / 60), tempC: 25)
        }
        let data = try XCTUnwrap(ReplayBuilder.make(title: "T", dateLabel: "1 Jan", startAtMs: 1_790_000_000_000, utcOffsetMin: 0, rows: rows,
                                                    stops: [], info: ReplayRideInfo(distanceM: 700)))
        let track = ReplayTrack.from(data)
        XCTAssertEqual(track.samples.count, 121)
        XCTAssertEqual(track.samples.last?.distM ?? 0, 700, accuracy: 1)        // the ride's own distance
        XCTAssertEqual(track.samples[60].lat ?? 0, 10 + 60 * 0.000_05, accuracy: 1e-5)
        XCTAssertFalse(track.has(.elevation), "no altitude readings: no Elevation layer")
        XCTAssertFalse(track.has(.power))
        XCTAssertEqual(track.samples.last?.batteryPct, 78)
    }

    func testRunsMergeOneColourStep() {
        let ramp = GradientRamp(lo: 0, hi: 50, hex: ["#000000", "#FFFFFF"])
        let p = (0..<5).map { GeoPoint(lat: 10 + Double($0) * 0.001, lon: -30) }
        let stretches = [ValueStretch(a: p[0], b: p[1], t: 0, value: 20), ValueStretch(a: p[1], b: p[2], t: 1, value: 21),
                         ValueStretch(a: p[2], b: p[3], t: 2, value: 45), ValueStretch(a: p[3], b: p[4], t: 3, value: 45)]
        let runs = ReplayTrack.runs(stretches, ramp: ramp, steps: 10)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].coords, [p[0], p[1], p[2]])
        XCTAssertEqual(runs[1].coords.count, 3)
    }

    func testBatteryAxisHasThreeTicks() {
        let a = ChartCursor.batteryAxis(min: 74, max: 81)
        XCTAssertEqual(a.domain, 70...90)
        XCTAssertEqual(a.ticks, [70, 80, 90])
        XCTAssertEqual(ChartCursor.batteryAxis(min: 3, max: 62).ticks, [0, 35, 70])
        XCTAssertEqual(ChartCursor.batteryAxis(min: 100, max: 100).domain, 90...100)
    }

    // MARK: Cursor

    func testCursorSnapsToTheNearestReading() {
        let times: [Double] = [0, 5, 10, 20]
        XCTAssertEqual(ChartCursor.lastIndex(times, atOrBefore: 12), 2)
        XCTAssertNil(ChartCursor.lastIndex(times, atOrBefore: -1))
        XCTAssertEqual(ChartCursor.nearestIndex(times, to: 7), 1)
        XCTAssertEqual(ChartCursor.nearestIndex(times, to: 8), 2)
        XCTAssertEqual(ChartCursor.nearestIndex(times, to: 99), 3)
        XCTAssertEqual(ChartCursor.nearestIndex(times, to: -3), 0)
        XCTAssertNil(ChartCursor.nearestIndex([], to: 1))
    }

    func testFingerAndTimeAreInverse() {
        let domain = 60.0...180.0
        XCTAssertEqual(ChartCursor.time(atX: 150, width: 300, domain: domain), 120, accuracy: 1e-9)
        XCTAssertEqual(ChartCursor.x(ofTime: 120, width: 300, domain: domain), 150, accuracy: 1e-9)
        XCTAssertEqual(ChartCursor.time(atX: -20, width: 300, domain: domain), 60)
        XCTAssertEqual(ChartCursor.time(atX: 999, width: 300, domain: domain), 180)
    }

    func testZoomStaysInsideTheRide() {
        let full = 0.0...600.0
        let z = ChartCursor.zoomed(full, full: full, scale: 4, anchor: 0.5)
        XCTAssertEqual(z.lowerBound, 225, accuracy: 1e-9)
        XCTAssertEqual(z.upperBound, 375, accuracy: 1e-9)
        let edge = ChartCursor.zoomed(full, full: full, scale: 4, anchor: 0)
        XCTAssertEqual(edge.lowerBound, 0)
        let tight = ChartCursor.zoomed(z, full: full, scale: 100)
        XCTAssertEqual(tight.upperBound - tight.lowerBound, 30, accuracy: 1e-9)
        XCTAssertEqual(ChartCursor.zoomed(z, full: full, scale: 0.01), full)
        let pan = ChartCursor.panned(z, full: full, byS: 1_000)
        XCTAssertEqual(pan.upperBound, 600)
        XCTAssertEqual(pan.upperBound - pan.lowerBound, 150, accuracy: 1e-9)
    }

    func testVisibleReadingsReachTheEdgesAndAreThinned() {
        let times = (0..<1_000).map(Double.init)
        let v = ChartCursor.visible(times, domain: 100.5...200.5)
        XCTAssertEqual(v.first, 100)
        XCTAssertEqual(v.last, 201)
        let thin = ChartCursor.visible(times, domain: 0...999, max: 100)
        XCTAssertEqual(thin.count, 100)
        XCTAssertEqual(thin.first, 0)
        XCTAssertEqual(thin.last, 999)
        XCTAssertEqual(ChartCursor.clock(754), "12:34")
        XCTAssertEqual(ChartCursor.clock(3_723), "1:02:03")
    }

    // MARK: B39

    func testMapFitIgnoresAWildFix() throws {
        var pts = (0..<50).map { GeoPoint(lat: 10 + Double($0) * 0.000_1, lon: -30) }
        pts.append(GeoPoint(lat: 10.4, lon: -29.6))      // ~60 km away
        XCTAssertEqual(MapFit.inliers(pts).count, 50)
        let r = try XCTUnwrap(MapFit.region(pts, padding: 0.15))
        XCTAssertLessThan(r.latSpan, 0.01)
        XCTAssertEqual(r.centerLat, 10 + 49 * 0.000_1 / 2, accuracy: 1e-9)
        // a long straight ride keeps both its ends
        let long = (0..<50).map { GeoPoint(lat: 10 + Double($0) * 0.002, lon: -30) }
        XCTAssertEqual(MapFit.inliers(long).count, 50)
    }

    func testMapFitPadsAndLeavesRoomForTheTopBar() throws {
        let pts = (0..<20).map { GeoPoint(lat: 10 + Double($0) * 0.001, lon: -30 + Double($0) * 0.001) }
        let r = try XCTUnwrap(MapFit.region(pts, padding: 0.15, topCover: 0.25))
        XCTAssertEqual(r.lonSpan, 0.019 * 1.3, accuracy: 1e-9)
        XCTAssertEqual(r.latSpan, 0.019 * 1.3 / 0.75, accuracy: 1e-9)
        XCTAssertGreaterThan(r.centerLat, 10 + 0.019 / 2)          // moved north: the path sits below the bar
        XCTAssertLessThanOrEqual(r.centerLat - r.latSpan / 2, 10)   // the south end is still on the map
        let side = try XCTUnwrap(MapFit.region(pts, padding: 0.15, sideCover: 0.25))
        XCTAssertEqual(side.lonSpan, 0.019 * 1.3 / 0.75, accuracy: 1e-9)
        XCTAssertGreaterThan(side.centerLon, -30 + 0.019 / 2)        // moved east: the path sits left of the layer control
        XCTAssertLessThanOrEqual(side.centerLon - side.lonSpan / 2, -30)
        XCTAssertNil(MapFit.region([]))
    }

    // MARK: B38

    func testClimbBatteryUsesOnlyTheClimbsOwnReadings() {
        // battery falls 95 -> 80 before the climb (t < 100), then 80 -> 79 on it
        var pts: [SeriesPoint] = []
        for i in 0..<200 {
            let pct = i < 100 ? 95 - i * 15 / 100 : (i < 150 ? 80 : 79)
            pts.append(SeriesPoint(t: Double(i), batteryPct: pct))
        }
        XCTAssertEqual(RideLayers.climbBatteryUsed(pts, from: 100, to: 199, distM: 600, gainM: 12), 1)
    }

    func testClimbBatteryHiddenBelowResolutionOrWhenImplausible() {
        let flat = (0..<60).map { SeriesPoint(t: Double($0), batteryPct: 80) }
        XCTAssertNil(RideLayers.climbBatteryUsed(flat, from: 0, to: 59, distM: 400, gainM: 12))
        // +12 m over 1.2 km with 16 % gone: sag, not energy (at most ~7 %)
        let sag = (0..<120).map { SeriesPoint(t: Double($0), batteryPct: $0 < 60 ? 80 : 64) }
        XCTAssertNil(RideLayers.climbBatteryUsed(sag, from: 0, to: 119, distM: 1_200, gainM: 12))
        // one sagging reading at the top does not count
        var spike = (0..<60).map { SeriesPoint(t: Double($0), batteryPct: $0 < 30 ? 80 : 78) }
        spike[59].batteryPct = 70
        XCTAssertEqual(RideLayers.climbBatteryUsed(spike, from: 0, to: 59, distM: 800, gainM: 30), 2)
        XCTAssertNil(RideLayers.climbBatteryUsed([SeriesPoint(t: 5, batteryPct: 80)], from: 0, to: 10, distM: 100, gainM: 6))
    }
}
