import XCTest
@testable import CorckieCore

/// B22 / F-10: the camera glide between fixes (synthetic coordinates).
final class LiveCameraTests: XCTestCase {
    private let lat0 = 10.0
    private let lon0 = 20.0
    private let metreDeg = 1.0 / 111_320.0

    func test_firstFixCentresOnTheFixWithNoHeading() {
        var t = LiveCameraTrack()
        let u = t.fix(lat: lat0, lon: lon0, atS: 100, speedKmh: 20)
        XCTAssertEqual(u.centerLat, lat0, accuracy: 1e-9)
        XCTAssertNil(u.headingDeg)
        XCTAssertEqual(u.durationS, 1.0, accuracy: 1e-9)
    }

    func test_movingNorthTurnsNorthAndPredictsOneSecondAhead() throws {
        var t = LiveCameraTrack()
        _ = t.fix(lat: lat0, lon: lon0, atS: 100, speedKmh: 36)
        let u = t.fix(lat: lat0 + 10 * metreDeg, lon: lon0, atS: 101, speedKmh: 36)
        XCTAssertEqual(try XCTUnwrap(u.headingDeg), 0, accuracy: 0.5)
        XCTAssertEqual((u.centerLat - lat0) / metreDeg, 20, accuracy: 0.5, "fix at 10 m plus 10 m predicted")
        XCTAssertEqual(u.durationS, 1.0, accuracy: 1e-9)
    }

    func test_headingIsHeldWhenSlowOrStopped() throws {
        var t = LiveCameraTrack()
        _ = t.fix(lat: lat0, lon: lon0, atS: 0, speedKmh: 30)
        _ = t.fix(lat: lat0, lon: lon0 + 8 * metreDeg / cos(lat0 * .pi / 180), atS: 1, speedKmh: 30)   // east
        let east = try XCTUnwrap(t.headingDeg)
        XCTAssertEqual(east, 90, accuracy: 0.5)
        // GPS noise while standing: a 3 m jump the other way at 2 km/h
        let u = t.fix(lat: lat0 + 3 * metreDeg, lon: lon0, atS: 2, speedKmh: 2)
        XCTAssertEqual(try XCTUnwrap(u.headingDeg), east, accuracy: 1e-9)
        XCTAssertEqual(u.centerLat, lat0 + 3 * metreDeg, accuracy: 1e-9, "no prediction while slow")
    }

    func test_predictionIsCappedAtOneAndAHalfSeconds() {
        var t = LiveCameraTrack()
        _ = t.fix(lat: lat0, lon: lon0, atS: 0, speedKmh: 36)
        let u = t.fix(lat: lat0 + 10 * metreDeg, lon: lon0, atS: 10, speedKmh: 36)   // 10 s without a fix
        XCTAssertEqual(u.durationS, LiveCameraTrack.maxAheadS, accuracy: 1e-9)
        XCTAssertLessThanOrEqual((u.centerLat - lat0 - 10 * metreDeg) / metreDeg, 15.01)
    }

    func test_turnsTheShortWayAcrossNorth() throws {
        var t = LiveCameraTrack()
        _ = t.fix(lat: lat0, lon: lon0, atS: 0, speedKmh: 30)
        _ = t.fix(lat: lat0 + 8 * metreDeg, lon: lon0 - 1 * metreDeg, atS: 1, speedKmh: 30)    // about 353
        let h1 = try XCTUnwrap(t.headingDeg)
        _ = t.fix(lat: lat0 + 16 * metreDeg, lon: lon0 + 1 * metreDeg, atS: 2, speedKmh: 30)   // about 7
        let h2 = try XCTUnwrap(t.headingDeg)
        XCTAssertTrue(h1 > 340 && (h2 < 20 || h2 > 340), "h1 \(h1) h2 \(h2)")
    }

    func test_cameraDistanceGrowsWithSpeedInSteps() {
        XCTAssertEqual(LiveCameraTrack.cameraDistanceM(speedKmh: 0), 450)
        XCTAssertEqual(LiveCameraTrack.cameraDistanceM(speedKmh: 25), 850)
        XCTAssertEqual(LiveCameraTrack.cameraDistanceM(speedKmh: 60), 950)
    }
}
