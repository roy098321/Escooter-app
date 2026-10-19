import XCTest
@testable import CorckieCore

/// V17: the "Parked · Work · 2 h ago" line and the pin position on Home's map picture. Made-up coordinates only.
final class ParkedSpotTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private func ago(_ minutes: Int) -> Int64 { now - Int64(minutes) * 60_000 }

    func test_ago_wording() {
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(0), nowMs: now), "just now")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(12), nowMs: now), "12 min ago")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(120), nowMs: now), "2 h ago")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(59), nowMs: now), "59 min ago")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(60), nowMs: now), "1 h ago")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(30 * 60), nowMs: now), "yesterday")
        XCTAssertEqual(ParkedText.ago(endedAtMs: ago(3 * 24 * 60 + 5), nowMs: now), "3 days ago")
        XCTAssertEqual(ParkedText.ago(endedAtMs: now + 5_000, nowMs: now), "just now", "a clock slightly ahead is not negative")
    }

    func test_line_withAndWithoutAPlace() {
        XCTAssertEqual(ParkedText.line(ParkedSpot(lat: 40, lon: -75, endedAtMs: ago(120), placeName: "Work"), nowMs: now), "Parked \u{00B7} Work \u{00B7} 2 h ago")
        XCTAssertEqual(ParkedText.line(ParkedSpot(lat: 40, lon: -75, endedAtMs: ago(45)), nowMs: now), "Parked \u{00B7} 45 min ago")
        XCTAssertEqual(ParkedText.line(ParkedSpot(lat: 40, lon: -75, endedAtMs: ago(45), placeName: "  "), nowMs: now), "Parked \u{00B7} 45 min ago")
    }

    func test_pinFraction_centreAndEdges() throws {
        let c = try XCTUnwrap(ParkedPin.fraction(lat: 40, lon: -75, centreLat: 40, centreLon: -75, spanLatM: 2_500, spanLonM: 1_153))
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
        // 500 m north is 20% up
        let north = try XCTUnwrap(ParkedPin.fraction(lat: 40 + 500 / 111_320, lon: -75, centreLat: 40, centreLon: -75, spanLatM: 2_500, spanLonM: 1_153))
        XCTAssertEqual(north.y, 0.3, accuracy: 1e-6)
        // 300 m east is right of the centre
        let east = try XCTUnwrap(ParkedPin.fraction(lat: 40, lon: -75 + 300 / (111_320 * cos(40 * .pi / 180)), centreLat: 40, centreLon: -75,
                                                    spanLatM: 2_500, spanLonM: 1_153))
        XCTAssertEqual(east.x, 0.5 + 300 / 1_153, accuracy: 1e-6)
    }

    func test_pinFraction_outsideThePicture_isNil() {
        XCTAssertNil(ParkedPin.fraction(lat: 40.05, lon: -75, centreLat: 40, centreLon: -75, spanLatM: 2_500, spanLonM: 1_153))
        XCTAssertNil(ParkedPin.fraction(lat: 40, lon: -75, centreLat: 40, centreLon: -75, spanLatM: 0, spanLonM: 1_153))
    }

    func test_scaledToFill_mapsTheFractionIntoTheView() {
        // a picture 430 x 932 drawn into a 390 x 844 view: the same shape, scale 0.907
        let aspect = 430.0 / 932.0
        let mid = ParkedPin.inFilledView((0.5, 0.5), imageAspect: aspect, viewWidth: 390, viewHeight: 844)
        XCTAssertEqual(mid.x, 195, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 422, accuracy: 1e-9)
        // a wider view crops the picture's top and bottom: the picture is as wide as the view and taller than it
        let wide = ParkedPin.inFilledView((0.0, 0.0), imageAspect: aspect, viewWidth: 500, viewHeight: 600)
        XCTAssertEqual(wide.x, 0, accuracy: 1e-9)
        XCTAssertLessThan(wide.y, 0, "the top of the picture is cut off")
    }
}
