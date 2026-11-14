import XCTest
@testable import CorckieCore

/// D2 7c: voltage class from a rested full-charge reading
final class VoltageClassTests: XCTestCase {
    func test_fullPackVoltagesMapToTheirClass() {
        XCTAssertEqual(VoltageClass.fromRestedFull(volts: 54.6), .v48)
        XCTAssertEqual(VoltageClass.fromRestedFull(volts: 58.8), .v52)
        XCTAssertEqual(VoltageClass.fromRestedFull(volts: 67.2), .v60)
    }

    func test_readingsThatCannotBeAFullPackGiveNoClass() {
        XCTAssertNil(VoltageClass.fromRestedFull(volts: 42.0))
        XCTAssertNil(VoltageClass.fromRestedFull(volts: 0))
        XCTAssertNil(VoltageClass.fromRestedFull(volts: 80))
    }

    func test_text() {
        XCTAssertEqual(VoltageClass.v52.text, "52 V")
    }
}
