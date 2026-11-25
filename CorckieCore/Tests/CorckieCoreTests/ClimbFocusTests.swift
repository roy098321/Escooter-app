@testable import CorckieCore
import XCTest

/// Hotfix .12 (owner 25 Nov): a climb row takes the map to that climb. Synthetic ride only.
final class ClimbFocusTests: XCTestCase {
    /// 200 readings 1 s apart heading north at 36 km/h (10 m/s): flat, a 30 m rise from 600 m to 1200 m, down 10 m, a 30 m rise 1500-1800 m
    private func ride() -> [SeriesPoint] {
        (0..<200).map { i in
            let d = Double(i) * 10
            let alt: Double
            switch d {
            case ..<600: alt = 10
            case ..<1200: alt = 10 + (d - 600) / 600 * 30
            case ..<1500: alt = 40 - (d - 1200) / 300 * 10
            case ..<1800: alt = 30 + (d - 1500) / 300 * 30
            default: alt = 60
            }
            return SeriesPoint(t: Double(i), lat: 10 + d / 111_320, lon: -30, hAccM: 5, speedKmh: 36, batteryPct: 80 - i / 20, altM: alt)
        }
    }

    func test_profileDistances_matchTheElevationProfile() {
        let pts = ride()
        let dist = RideLayers.profileDistances(pts)
        let profile = RideLayers.elevation(pts).profile
        XCTAssertEqual(dist.last ?? 0, 1990, accuracy: 5)
        XCTAssertEqual(profile.last?.distM ?? 0, dist.last ?? -1, accuracy: 0.01, "the same ruler as the chart")
    }

    func test_focus_isTheClimbsOwnStretch() throws {
        let pts = ride()
        let climbs = RideLayers.elevation(pts).climbs
        XCTAssertEqual(climbs.count, 2)
        let f = try XCTUnwrap(ClimbFocus.make(pts, climbs: climbs, index: 0))
        XCTAssertEqual(f.title, "Climb 1")
        let lats = f.coords.map { ($0.lat - 10) * 111_320 }
        XCTAssertEqual(lats.first ?? 0, climbs[0].startDistM, accuracy: 15)
        XCTAssertEqual(lats.last ?? 0, climbs[0].endDistM, accuracy: 15)
        XCTAssertLessThan(lats.last ?? 9999, 1500, "stops at the top, not the next climb")
        XCTAssertTrue(f.line.hasPrefix("km 0."), f.line)
        XCTAssertTrue(f.line.contains("+"))
        let second = try XCTUnwrap(ClimbFocus.make(pts, climbs: climbs, index: 1))
        XCTAssertEqual(second.title, "Climb 2")
        XCTAssertGreaterThan(second.coords.first?.lat ?? 0, f.coords.last?.lat ?? 99)
    }

    func test_focus_withoutGps_isNil() {
        let pts = ride().map { var p = $0; p.lat = nil; p.lon = nil; return p }
        let climbs = RideLayers.elevation(pts).climbs
        XCTAssertNil(ClimbFocus.make(pts, climbs: climbs, index: 0))
        XCTAssertNil(ClimbFocus.make(ride(), climbs: [], index: 0))
    }

    func test_step_wrapsRound() {
        XCTAssertEqual(ClimbFocus.step(0, by: 1, count: 5), 1)
        XCTAssertEqual(ClimbFocus.step(4, by: 1, count: 5), 0)
        XCTAssertEqual(ClimbFocus.step(0, by: -1, count: 5), 4)
        XCTAssertEqual(ClimbFocus.step(0, by: 1, count: 0), 0)
    }
}
