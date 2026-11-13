import XCTest
@testable import CorckieCore

/// N5-1: the privacy-safe export rules. Made-up coordinates only.
final class PrivacyExportTests: XCTestCase {
    func test_distanceAndZone() {
        // 0.002 degrees of latitude is about 222 m
        XCTAssertEqual(PrivacyExport.distanceM(10.0, 20.0, 10.002, 20.0), 222.4, accuracy: 1.5)
        let zones = [(lat: 10.0, lon: 20.0)]
        XCTAssertTrue(PrivacyExport.inZone(lat: 10.001, lon: 20.0, zones: zones), "111 m is inside 200 m")
        XCTAssertFalse(PrivacyExport.inZone(lat: 10.003, lon: 20.0, zones: zones), "333 m is outside")
    }

    func test_namesAndPlacesAreBlankedForPrivateLevels() {
        for table in ["place", "route", "variant", "stop", "scooter", "ride_note"] {
            XCTAssertNotNil(PrivacyExport.blankedColumns[table], table)
        }
        XCTAssertTrue(PrivacyExport.blankedColumns["place"]!.contains("lat"))
        XCTAssertEqual(PrivacyLevel.allCases.count, 3)
    }

    func test_everyBlankedColumnIsKnownToTheDataMap() {
        // a blanked column that is not even in the schema map would be a typo
        for (table, columns) in PrivacyExport.blankedColumns {
            XCTAssertNotNil(DataMap.category(table: table), table)
            XCTAssertFalse(columns.isEmpty)
        }
    }
}
