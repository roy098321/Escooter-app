@testable import CorckieCore
@testable import CorckieSim
import XCTest

/// Hotfix .13 (owner 25 Nov): the ride map follows the road. Synthetic numbers only.
final class TrackMergeTests: XCTestCase {
    private func fix(_ t: Double, _ lat: Double = 10, _ lon: Double = -30) -> PhoneFix {
        PhoneFix(t: t, lat: lat, lon: lon, hAccM: 5, speedMps: 19)
    }

    func test_trackPacksAndUnpacks() {
        let fixes = [fix(100), fix(101, 10.0001, -30.0002), fix(102.5, 10.0003, -30.0001)]
        let d = RecorderTrack.pack(fixes, startT: 100)
        XCTAssertEqual(d.count, 3 * RecorderTrack.bytesPerFix)
        let back = RecorderTrack.unpack(d, startT: 100)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[2].t, 102.5, accuracy: 0.001)
        XCTAssertEqual(back[1].lat, 10.0001, accuracy: 1e-12)
        XCTAssertEqual(back[1].lon, -30.0002, accuracy: 1e-12)
        XCTAssertEqual(back[0].hAccM, 5, accuracy: 0.001)
    }

    func test_fixesGoBetweenSamples_readingsInterpolated() {
        let a = SeriesPoint(t: 0, lat: 10, lon: -30, hAccM: 5, speedKmh: 60, batteryPct: 80, altM: 10, powerW: 1000, tempC: 40)
        let b = SeriesPoint(t: 5, lat: 10.001, lon: -30, hAccM: 5, speedKmh: 70, batteryPct: 79, altM: 20, powerW: 2000, tempC: 42)
        let track = (1...4).map { (t: Double($0), lat: 10 + Double($0) * 0.0002, lon: -30.0001, hAccM: 4.0) }
        let m = TrackMerge.merge([a, b], track: track)
        XCTAssertEqual(m.count, 6)
        XCTAssertEqual(m.map(\.t), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(m[2].lon, -30.0001, "the position is the fix's own")
        XCTAssertEqual(m[2].speedKmh ?? 0, 64, accuracy: 0.001)
        XCTAssertEqual(m[2].altM ?? 0, 14, accuracy: 0.001)
        XCTAssertEqual(m[2].batteryPct, 80)
        XCTAssertTrue(m[2].hasFix)
    }

    func test_timeWeightedSumsDoNotChange() throws {
        // 100 s of samples every 5 s at 60 then 70 km/h; adding the 1-s fixes keeps At top speed the same
        var pts: [SeriesPoint] = []
        for i in 0...20 { pts.append(SeriesPoint(t: Double(i * 5), lat: 10 + Double(i) * 0.0005, lon: -30, hAccM: 5, speedKmh: i < 10 ? 60 : 70)) }
        let track = (1..<100).map { (t: Double($0), lat: 10 + Double($0) * 0.0001, lon: -30.00001, hAccM: 5.0) }
        let before = try XCTUnwrap(TopSpeedShare.make(pts))
        let after = try XCTUnwrap(TopSpeedShare.make(TrackMerge.merge(pts, track: track)))
        XCTAssertEqual(after.movingS, before.movingS, accuracy: 0.01)
        XCTAssertLessThanOrEqual(abs(after.pct - before.pct), 3)
    }

    func test_nothingMadeUpAcrossAGap_orOutsideTheRide() {
        let a = SeriesPoint(t: 0, lat: 10, lon: -30, hAccM: 5, speedKmh: 60)
        let b = SeriesPoint(t: 100, lat: 10.01, lon: -30, hAccM: 5, speedKmh: 60)
        let track = [(t: -5.0, lat: 9.0, lon: -30.0, hAccM: 5.0), (t: 50, lat: 10.005, lon: -30, hAccM: 5), (t: 120, lat: 11, lon: -30, hAccM: 5)]
        let m = TrackMerge.merge([a, b], track: track)
        XCTAssertEqual(m.count, 3, "before the start and after the end (a trimmed ride) are left out")
        XCTAssertNil(m[1].speedKmh, "no speed made up across a 100 s gap")
        XCTAssertEqual(m[1].lat, 10.005)
        XCTAssertEqual(TrackMerge.merge([a, b], track: []), [a, b], "a ride from before .13 is unchanged")
    }

    func test_recorderKeepsOneGoodFixASecond_andFlushesItWithTheChunks() throws {
        // the F2 fixture ride (scooter packets) with a made-up phone fix every 0.25 s; 5 s of them too inaccurate to keep
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F2" })
        let events = try sim.events(from: Fixtures.text("F2_ride1_nrf.csv"))
        let t0 = try XCTUnwrap(events.first?.t), t1 = try XCTUnwrap(events.last?.t)
        var phone: [TimedPhoneEvent] = []
        var t = t0
        while t <= t1 {
            let bad = t - t0 > 100 && t - t0 < 105
            phone.append(TimedPhoneEvent(t: t, event: .fix(PhoneFix(t: t, lat: 10 + (t - t0) * 0.00005, lon: -30, hAccM: bad ? 200 : 5, speedMps: 5))))
            t += 0.25
        }
        var tracks: [(startT: Double, blob: Data)] = []
        var core = RideRecorderCore()
        RecorderRunner.play(RecorderRunner.inputs(SimStream(scooter: events, phone: phone)), core: &core) { a in
            if case let .trackChunk(_, s, _, blob) = a { tracks.append((s, blob)) }
        }
        XCTAssertGreaterThan(tracks.count, 1, "written with the 30-s flushes and at the end")
        let all = tracks.flatMap { RecorderTrack.unpack($0.blob, startT: $0.startT) }
        let gaps = zip(all, all.dropFirst()).map { $1.t - $0.t }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 0.9, "one fix a second at most")
        XCTAssertTrue(all.allSatisfy { $0.hAccM <= 50 }, "inaccurate fixes are not kept")
        XCTAssertGreaterThan(all.count, 30)
    }
}

/// Hotfix .14 (owner 26 Nov): the ride line goes through every 1-s fix, not one point per 25 m.
final class Hotfix14LineTests: XCTestCase {
    func test_piecesGoThroughEveryFix() {
        // 60 s at 36 km/h along a quarter circle, one fix a second
        let pts: [SeriesPoint] = (0...60).map { i in
            let a = Double(i) / 60 * Double.pi / 2
            return SeriesPoint(t: Double(i), lat: 10 + 0.003 * sin(a), lon: -30 + 0.003 * (1 - cos(a)), hAccM: 5, speedKmh: 36)
        }
        let stretches = RideLayers.speedStretches(pts)
        XCTAssertLessThan(stretches.count, 40, "still one value per ~25 m")
        let pieces = RoutePieces.pieces(stretches, ramp: LayerRamps.speed(colourBlind: false))
        let drawn = pieces.reduce(0) { $0 + $1.coords.count }
        XCTAssertGreaterThanOrEqual(drawn, 55, "but the line is drawn through (almost) every fix")
        XCTAssertEqual(pieces.count, 1, "one colour: one piece")
    }

    func test_oldRideWithoutTrack_unchanged() {
        let a = GeoPoint(lat: 10, lon: -30), b = GeoPoint(lat: 10.001, lon: -30)
        let p = RoutePieces.pieces([ValueStretch(a: a, b: b, t: 0, value: 20)], ramp: LayerRamps.speed(colourBlind: false))
        XCTAssertEqual(p.first?.coords, [a, b])
    }
}
