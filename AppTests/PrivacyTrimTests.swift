import CorckieCore
import Foundation
import XCTest

/// N5-1: the privacy-safe export on made-up tables.
final class PrivacyTrimTests: XCTestCase {
    private func samples() -> BundleTable {
        // a ride from (10.000, 20.000) away to (10.010, 20.000): about 1.1 km
        var rows: [[BundleValue]] = []
        for i in 0...10 {
            rows.append([.text("r1"), .int(Int64(i)), .double(5), .double(10.0 + Double(i) * 0.001), .double(20.0), .int(80)])
        }
        return BundleTable(name: "ride_sample", columns: ["rideId", "t", "speedMps", "lat", "lon", "batteryPct"], rows: rows)
    }

    func test_trimmed_removesAroundStartAndEnd_keepsTheMiddleAndTheRest() {
        let out = PrivacyTrim.trimSamples(samples(), level: .trimmed, placeZones: [])
        let lat = out.columns.firstIndex(of: "lat")!
        let battery = out.columns.firstIndex(of: "batteryPct")!
        XCTAssertEqual(out.rows[0][lat], .null, "start")
        XCTAssertEqual(out.rows[10][lat], .null, "end")
        XCTAssertNotEqual(out.rows[5][lat], .null, "the middle stays")
        XCTAssertEqual(out.rows[0][battery], .int(80), "battery readings are kept")
    }

    func test_noGPS_removesEveryCoordinate() {
        let out = PrivacyTrim.trimSamples(samples(), level: .noGPS, placeZones: [])
        let lat = out.columns.firstIndex(of: "lat")!
        let lon = out.columns.firstIndex(of: "lon")!
        XCTAssertTrue(out.rows.allSatisfy { $0[lat] == .null && $0[lon] == .null })
    }

    func test_savedPlaceZoneIsTrimmedInTheMiddleOfARide() {
        let out = PrivacyTrim.trimSamples(samples(), level: .trimmed, placeZones: [(lat: 10.005, lon: 20.0)])
        let lat = out.columns.firstIndex(of: "lat")!
        XCTAssertEqual(out.rows[5][lat], .null)
        XCTAssertEqual(out.rows[4][lat], .null, "111 m from the place")
        XCTAssertNotEqual(out.rows[3][lat], .null, "222 m away stays")
    }

    func test_placeNamesAndCoordinatesAreBlanked() {
        let place = BundleTable(name: "place", columns: ["id", "name", "lat", "lon", "radiusM"],
                                rows: [[.text("p1"), .text("Synthetic Home"), .double(10), .double(20), .double(50)]])
        let out = PrivacyTrim.blank(place)
        XCTAssertEqual(out.rows[0][1], .null)
        XCTAssertEqual(out.rows[0][2], .null)
        XCTAssertEqual(out.rows[0][3], .null)
        XCTAssertEqual(out.rows[0][4], .double(50), "other columns stay")
        XCTAssertEqual(PrivacyTrim.zonesFromPlaces(place).count, 1, "the zones come from the unblanked table")
    }

    func test_fullLevelChangesNothing() {
        XCTAssertEqual(PrivacyTrim.trimSamples(samples(), level: .full, placeZones: []), samples())
    }
}
