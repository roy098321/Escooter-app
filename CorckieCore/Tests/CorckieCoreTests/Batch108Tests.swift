import CorckieCore
import XCTest

/// Batch 8 guard tests (in-ride signals).
final class Batch108Tests: XCTestCase {
    func test_N8_2_batteryTileLevels() {
        XCTAssertEqual(BatteryTileLevel.level(pct: 21), .normal)
        XCTAssertEqual(BatteryTileLevel.level(pct: 20), .low)
        XCTAssertEqual(BatteryTileLevel.level(pct: 11), .low)
        XCTAssertEqual(BatteryTileLevel.level(pct: 10), .critical)
        XCTAssertEqual(BatteryTileLevel.level(pct: nil), .normal)
        XCTAssertEqual(BatteryTileLevel.number("18%", level: .low, colourBlind: true), "\u{25BC} 18%")
        XCTAssertEqual(BatteryTileLevel.number("18%", level: .low, colourBlind: false), "18%")
    }
}
