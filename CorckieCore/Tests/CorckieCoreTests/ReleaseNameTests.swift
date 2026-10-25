import XCTest
@testable import CorckieCore

/// F-30b: one release name everywhere, VB.DDMMYY.HH.
final class ReleaseNameTests: XCTestCase {
    func testFormat() {
        XCTAssertTrue(ReleaseName.isValid("101.251026.00"))
        XCTAssertTrue(ReleaseName.isValid("102.011126.01"))
        XCTAssertFalse(ReleaseName.isValid("1.0"))
        XCTAssertFalse(ReleaseName.isValid("101.2510.00"))
        XCTAssertFalse(ReleaseName.isValid("101.25102a.00"))
        XCTAssertEqual(ReleaseName.code("101.251026.00"), "251026")
        XCTAssertEqual(ReleaseName.code("1.0"), "1.0")
        XCTAssertEqual(ReleaseName.fileStem("101.251026.00"), "CorckieApp-101.251026.00")
    }
}
