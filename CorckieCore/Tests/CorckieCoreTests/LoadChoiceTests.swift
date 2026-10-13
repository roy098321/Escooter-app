import XCTest
@testable import CorckieCore

/// F-02: the Load selector's stored choice and what is attached to the next ride.
final class LoadChoiceTests: XCTestCase {
    func test_storedRoundTrip() {
        for choice in [LoadChoice.empty, LoadChoice(level: .light), LoadChoice(level: .heavy), LoadChoice(level: .custom, customKg: 7.5)] {
            XCTAssertEqual(LoadChoice(stored: choice.stored), choice)
        }
        XCTAssertEqual(LoadChoice(level: .custom, customKg: 7.5).stored, "custom:7.5")
    }

    func test_badOrMissingText_isNil() {
        XCTAssertNil(LoadChoice(stored: nil))
        XCTAssertNil(LoadChoice(stored: ""))
        XCTAssertNil(LoadChoice(stored: "custom"))
        XCTAssertNil(LoadChoice(stored: "custom:abc"))
        XCTAssertNil(LoadChoice(stored: "custom:250"))
        XCTAssertNil(LoadChoice(stored: "custom:-3"))
        XCTAssertNil(LoadChoice(stored: "banana"))
    }

    func test_attachment_usesTheSettingsLevels_noneAttachesNothing() {
        XCTAssertNil(LoadChoice.empty.attachment(lightKg: 5, heavyKg: 15))
        XCTAssertEqual(LoadChoice(level: .light).attachment(lightKg: 5, heavyKg: 15)?.kg, 5)
        XCTAssertEqual(LoadChoice(level: .heavy).attachment(lightKg: 5, heavyKg: 18)?.kg, 18)
        let exact = LoadChoice(level: .custom, customKg: 9).attachment(lightKg: 5, heavyKg: 15)
        XCTAssertEqual(exact?.level, .custom)
        XCTAssertEqual(exact?.kg, 9)
        XCTAssertNil(LoadChoice(level: .custom, customKg: 0).attachment(lightKg: 5, heavyKg: 15))
    }
}
