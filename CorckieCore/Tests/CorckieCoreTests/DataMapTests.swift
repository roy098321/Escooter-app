import XCTest
@testable import CorckieCore

final class DataMapTests: XCTestCase {
    func test_everyMixedTableIsListedAsATable() {
        for table in DataMap.mixedColumns.keys { XCTAssertNotNil(DataMap.tables[table], table) }
    }

    func test_rideBatteryColumnsAreScooterData() {
        for column in ["usedPct", "usedPctShown", "energyWhCal", "startRestV", "scooterId"] {
            XCTAssertEqual(DataMap.category(table: "ride", column: column), .scooter, column)
        }
        for column in ["startAt", "distanceM", "routeId"] {
            XCTAssertEqual(DataMap.category(table: "ride", column: column), .rider, column)
        }
        XCTAssertNil(DataMap.category(table: "ride", column: "madeUpColumn"))
    }

    func test_scooterAndAccuracyTablesAlwaysStartOver() {
        XCTAssertEqual(DataMap.wholeTables(.scooter), ["calibration", "charge", "factor_effect", "maintenance_item",
                                                        "scooter", "untracked_distance", "wheel_calibration"])
        XCTAssertEqual(DataMap.wholeTables(.accuracy), ["prediction", "shadow_result"])
    }

    func test_scooterSettingKeys() {
        XCTAssertTrue(DataMap.isScooterSetting("battery.packAh"))
        XCTAssertFalse(DataMap.isScooterSetting("rider.loadKg"))
    }

    func test_foundTextNamesModelKmAndBattery() {
        XCTAssertEqual(KnownScooters.modelName(advertisedName: "G2", makerTagged: true), "RND G100")
        XCTAssertEqual(KnownScooters.modelName(advertisedName: nil, makerTagged: true), "Scooter (RND type)")
        XCTAssertEqual(KnownScooters.foundText(model: "RND G100", odometerKm: 3.2, batteryPct: 87), "RND G100 \u{00B7} 3 km \u{00B7} 87 %")
        XCTAssertEqual(KnownScooters.foundText(model: "RND G100", odometerKm: nil, batteryPct: nil), "RND G100")
    }
}
