@testable import CorckieCore
import XCTest

/// Hotfix .12 (owner 25 Nov): "At top speed" = moving time within 10 % of the ride's top speed; tiles turn over to explain.
final class TopSpeedShareTests: XCTestCase {
    private func ride(_ speeds: [Double]) -> [SeriesPoint] {
        speeds.enumerated().map { SeriesPoint(t: Double($0.offset), speedKmh: $0.element) }
    }

    func test_ownersExample_70topCounts63to70() throws {
        // 100 s at 50, 25 s at 65, 25 s at 70, 50 s standing (left out), then one last reading
        let s = try XCTUnwrap(TopSpeedShare.make(ride(Array(repeating: 50, count: 100) + Array(repeating: 65, count: 25)
            + Array(repeating: 70, count: 25) + Array(repeating: 0, count: 50) + [0])))
        XCTAssertEqual(s.topKmh, 70)
        XCTAssertEqual(s.loKmh, 63)
        XCTAssertEqual(s.movingS, 150, accuracy: 0.01, "standing still is not moving time")
        XCTAssertEqual(s.bandS, 50, accuracy: 0.01)
        XCTAssertEqual(s.pct, 33)
        XCTAssertEqual(s.text, "33%")
        XCTAssertEqual(s.bandText, "63\u{2013}70 km/h")
    }

    func test_lostLinkGapIsNotCounted() throws {
        var pts = ride(Array(repeating: 70, count: 10) + Array(repeating: 40, count: 11))
        for i in 10..<pts.count { pts[i].t += 600 }          // 10 min with no readings after riding at 70
        let s = try XCTUnwrap(TopSpeedShare.make(pts))
        XCTAssertEqual(s.movingS, 19, accuracy: 0.01)
        XCTAssertEqual(s.pct, 47)                            // 9 of 19 s
    }

    func test_noSpeed_isNil() {
        XCTAssertNil(TopSpeedShare.make([SeriesPoint(t: 0), SeriesPoint(t: 1)]))
        XCTAssertNil(TopSpeedShare.make(ride([0, 0, 1])))
    }

    func test_everyTileHasABack_shortEnoughForTheTile() throws {
        let share = try XCTUnwrap(TopSpeedShare.make(ride([50, 64, 71, 71, 30])))
        for label in ["Time", "Distance", "Avg speed", "Battery", "Top speed", "Climb", "At top speed", "km left"] {
            let b = try XCTUnwrap(TileBack.forTile(label, movingText: "38:02", share: share), label)
            for line in [b.lead, b.key, b.small] { XCTAssertLessThanOrEqual(line.count, 24, "\(label): \(line)") }
        }
        XCTAssertEqual(TileBack.forTile("At top speed", share: share)?.key, "64\u{2013}71 km/h")
        XCTAssertEqual(TileBack.forTile("Time", movingText: "38:02")?.small, "moving 38:02")
        XCTAssertNil(TileBack.forTile("Cost"))
        XCTAssertEqual(TileBack.clock(455), "7:35")
        XCTAssertEqual(TileBack.clock(3725), "1:02:05")
    }
}
