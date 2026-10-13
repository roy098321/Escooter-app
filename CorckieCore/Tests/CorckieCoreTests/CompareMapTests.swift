import XCTest
@testable import CorckieCore

/// F-05: two rides on one map. The time difference is aligned by distance along the path, never by the clock.
final class CompareMapTests: XCTestCase {
    static let lat0 = 32.0
    static let lon0 = 34.8
    static let mPerDeg = Geo.mPerDegLat

    /// A point `north` m north and `east` m east of the origin
    private func coord(north: Double, east: Double = 0) -> (Double, Double) {
        (Self.lat0 + north / Self.mPerDeg, Self.lon0 + east / (Self.mPerDeg * cos(Self.lat0 * .pi / 180)))
    }

    private func ridePoint(_ tS: Double, north: Double, east: Double = 0, kmh: Double? = nil) -> RidePoint {
        let c = coord(north: north, east: east)
        return RidePoint(t: Int64(tS * 1000), lat: c.0, lon: c.1, hAccM: 5, speedKmh: kmh)
    }

    /// Straight line north at a constant speed, one point every 5 s
    private func line(speed: Double, duration: Double) -> ComparePath {
        var pts: [RidePoint] = []
        var t = 0.0
        while t <= duration + 1e-9 {
            pts.append(ridePoint(t, north: speed * t, kmh: speed * 3.6))
            t += 5
        }
        return ComparePath.build(pts)
    }

    func test_build_timeAndDistanceFromTheFirstPoint_badFixesLeftOut() {
        let pts = [ridePoint(7, north: 0), ridePoint(12, north: 50),
                   RidePoint(t: 14_000, lat: 40, lon: 40, hAccM: 300),
                   RidePoint(t: 15_000, lat: nil, lon: nil),
                   ridePoint(17, north: 100)]
        let p = ComparePath.build(pts)
        XCTAssertEqual(p.points.count, 3)
        XCTAssertEqual(p.points[0].t, 0)
        XCTAssertEqual(p.points[2].t, 10, accuracy: 1e-9)
        XCTAssertEqual(p.lengthM, 100, accuracy: 0.5)
    }

    func test_timeDifference_isAlignedByDistance_notByTheClock() {
        let a = line(speed: 10, duration: 100)          // 1000 m in 100 s
        let b = line(speed: 8, duration: 125)           // 1000 m in 125 s
        let m = CompareAlign.match(a, b)
        XCTAssertEqual(m.count, a.points.count)
        // at 500 m (A: 50 s) B needs 62.5 s: B is 12.5 s later
        let mid = m[10]!
        XCTAssertEqual(mid.timeA, 50, accuracy: 1e-9)
        XCTAssertEqual(mid.timeB, 62.5, accuracy: 0.2)
        XCTAssertEqual(mid.deltaS, 12.5, accuracy: 0.2)
        // at the end: 25 s
        XCTAssertEqual(m.last!!.deltaS, 25, accuracy: 0.3)
        // swapped: the sign flips
        let back = CompareAlign.match(b, a)
        XCTAssertEqual(back.last!!.deltaS, -25, accuracy: 0.3)
    }

    func test_aStopShowsAsTheDifferenceGrowingAtThatSpot() {
        let a = line(speed: 10, duration: 100)
        // B: 8 m/s, a 20 s stop at 500 m
        let b = ComparePath.build([ridePoint(0, north: 0), ridePoint(62.5, north: 500), ridePoint(82.5, north: 500), ridePoint(145, north: 1000)])
        let m = CompareAlign.match(a, b)
        // A at 250 m (25 s): B at 31.25 s -> +6.25 s; at 750 m (75 s): B at 113.75 s -> +38.75 s
        XCTAssertEqual(m[5]!.deltaS, 6.25, accuracy: 0.3)
        XCTAssertEqual(m[15]!.deltaS, 38.75, accuracy: 0.3)
        XCTAssertGreaterThan(m[15]!.deltaS - m[5]!.deltaS, 30)
    }

    func test_whereTheRidesTookDifferentRoads_thereIsNoMatch() {
        let a = line(speed: 10, duration: 100)
        // B detours 500 m east between 250 m and 750 m of its path, then comes back and goes on
        let b = ComparePath.build([ridePoint(0, north: 0), ridePoint(30, north: 250), ridePoint(80, north: 250, east: 500),
                                   ridePoint(130, north: 250), ridePoint(160, north: 500), ridePoint(240, north: 1000)])
        let m = CompareAlign.match(a, b)
        XCTAssertNotNil(m[2])                       // 100 m: shared
        XCTAssertNil(m[8])                          // 400 m: B was 500 m east on its detour road
        XCTAssertNil(CompareAlign.delta(atTimeA: 60, matches: m, path: a), "no time difference on a different road")
        XCTAssertNotNil(CompareAlign.delta(atTimeA: 10, matches: m, path: a))
    }

    func test_aLoopsStartNeverMatchesItsEnd() {
        // a 100 m square loop ridden once by each: start and end are at the same spot
        func loop(speed: Double) -> ComparePath {
            let corners: [(Double, Double)] = [(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)]
            var pts: [RidePoint] = []
            var t = 0.0
            for (i, c) in corners.enumerated() {
                pts.append(ridePoint(t, north: c.0, east: c.1))
                t += 100 / speed
                _ = i
            }
            return ComparePath.build(pts)
        }
        let m = CompareAlign.match(loop(speed: 10), loop(speed: 5))
        XCTAssertEqual(m.first!!.timeB, 0, accuracy: 0.01, "the start matches the start")
        XCTAssertEqual(m.last!!.timeB, 80, accuracy: 0.5, "the end matches the end")
    }

    func test_deltaAtATime_blendsBetweenPoints() {
        let a = line(speed: 10, duration: 100)
        let b = line(speed: 8, duration: 125)
        let m = CompareAlign.match(a, b)
        XCTAssertEqual(CompareAlign.delta(atTimeA: 50, matches: m, path: a) ?? -1, 12.5, accuracy: 0.3)
        XCTAssertEqual(CompareAlign.delta(atTimeA: 52.5, matches: m, path: a) ?? -1, 13.1, accuracy: 0.3)
    }

    func test_positionAtTime_interpolatesAndHoldsAtTheEnds() {
        let p = line(speed: 10, duration: 100)
        XCTAssertEqual(p.position(atTime: 12.5)!.distM, 125, accuracy: 0.5)
        XCTAssertEqual(p.position(atTime: -3)!.distM, 0)
        XCTAssertEqual(p.position(atTime: 999)!.distM, p.lengthM, accuracy: 1e-9)
        XCTAssertEqual(p.position(atTime: 12.5)!.speedKmh!, 36, accuracy: 1e-6)
        XCTAssertNil(ComparePath(points: []).position(atTime: 1))
    }

    func test_tapReadout_bothRidesAtTheSameSpot() {
        let a = line(speed: 10, duration: 100)
        let b = line(speed: 8, duration: 125)
        let tap = coord(north: 400, east: 8)
        let ra = a.readout(nearLat: tap.0, lon: tap.1)!
        let rb = b.readout(nearLat: tap.0, lon: tap.1)!
        XCTAssertEqual(ra.timeS, 40, accuracy: 0.3)
        XCTAssertEqual(rb.timeS, 50, accuracy: 0.3)
        XCTAssertEqual(ra.speedKmh ?? 0, 36, accuracy: 0.1)
        XCTAssertEqual(rb.speedKmh ?? 0, 28.8, accuracy: 0.1)
        let far = coord(north: 400, east: 300)
        XCTAssertNil(a.readout(nearLat: far.0, lon: far.1), "a tap far from the line reads nothing")
    }

    func test_offset_movesTheLineSidewaysByMetres() {
        let p = line(speed: 10, duration: 50)
        let right = p.offset(byM: 10)               // heading north: right = east
        let d = Geo.distanceM(GeoPoint(lat: p.points[3].lat, lon: p.points[3].lon), GeoPoint(lat: right.points[3].lat, lon: right.points[3].lon))
        XCTAssertEqual(d, 10, accuracy: 0.2)
        XCTAssertGreaterThan(right.points[3].lon, p.points[3].lon)
        XCTAssertEqual(p.offset(byM: 0), p)
        XCTAssertEqual(right.points[3].t, p.points[3].t)
    }

    func test_playbackClock_oneClock_speedOneToFifty_stopsAtTheEnd() {
        var c = ComparePlayback(durationS: 100)
        c.setSpeed(500)
        XCTAssertEqual(c.speed, 50)
        c.setSpeed(0)
        XCTAssertEqual(c.speed, 1)
        c.setSpeed(10)
        c.advance(by: 1)
        XCTAssertEqual(c.time, 0, "paused clocks do not move")
        c.play()
        c.advance(by: 2)
        XCTAssertEqual(c.time, 20, accuracy: 1e-9)
        c.scrub(to: 95)
        c.advance(by: 1)
        XCTAssertEqual(c.time, 100)
        XCTAssertFalse(c.playing)
        c.play()                                     // at the end: starts over
        XCTAssertEqual(c.time, 0)
        XCTAssertTrue(c.playing)
        XCTAssertEqual(ComparePlayback.speeds.first, 1)
        XCTAssertEqual(ComparePlayback.speeds.last, 50)
    }

    func test_text_signedClock_andNeutralSentence() {
        XCTAssertEqual(CompareAlign.clock(42), "+0:42")
        XCTAssertEqual(CompareAlign.clock(-7), "\u{2212}0:07")
        XCTAssertEqual(CompareAlign.clock(0), "0:00")
        XCTAssertEqual(CompareAlign.clock(3_725), "+1:02:05")
        XCTAssertEqual(CompareAlign.timeFromStart(-95), "1:35")
        XCTAssertEqual(CompareAlign.differenceText(42), "B is 0:42 later at this point")
        XCTAssertEqual(CompareAlign.differenceText(-7), "B is 0:07 earlier at this point")
        XCTAssertEqual(CompareAlign.differenceText(0.2), "A and B are together at this point")
        XCTAssertEqual(CompareAlign.differenceText(nil), "The rides took different roads here")
        // P-3: nothing in the wording ranks the rides
        for text in [CompareAlign.differenceText(42), CompareAlign.differenceText(-7)] {
            for word in ["win", "won", "lose", "lost", "best", "record", "score", "beat", "faster", "slower"] {
                XCTAssertFalse(text.lowercased().contains(word), text)
            }
        }
    }
}
