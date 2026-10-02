import XCTest
@testable import CorckieCore

/// F09: every outside source has a parser checked against a saved real response
/// (captured at the fake ocean point 10, -30, so no personal location is in them).
final class OutsideParsersTests: XCTestCase {
    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.url("outside/" + name))
    }

    func test_openMeteoForecast() throws {
        let hours = try OutsideParsers.openMeteoHourly(data("open-meteo-forecast.json"))
        XCTAssertEqual(hours.count, 24)
        XCTAssertNotNil(hours.first?.windFromDeg)
        XCTAssertNotNil(hours.first?.airTempC)
    }

    func test_openMeteoHistory() throws {
        let hours = try OutsideParsers.openMeteoHourly(data("open-meteo-history.json"))
        XCTAssertEqual(hours.count, 24)
    }

    func test_metNorway_convertsWindToKmh() throws {
        let hours = try OutsideParsers.metNorwayHourly(data("met-norway.json"))
        XCTAssertGreaterThan(hours.count, 24)
        XCTAssertTrue(hours.allSatisfy { $0.windKmh >= 0 && $0.windKmh < 250 })
    }

    func test_elevation() throws {
        XCTAssertEqual(try OutsideParsers.elevations(data("open-meteo-elevation.json")), [0.0])
        XCTAssertThrowsError(try OutsideParsers.elevations(Data("{\"elevation\":[99999]}".utf8)))
    }

    func test_hebcal_israelHolidaysAndEves() throws {
        let days = try OutsideParsers.holidays(data("hebcal-2026.json"))
        XCTAssertTrue(days.contains { $0.name == "Yom Kippur" && $0.date == "2026-09-21" && $0.kind == .holiday })
        XCTAssertTrue(days.contains { $0.name == "Erev Yom Kippur" && $0.kind == .eve })
        XCTAssertGreaterThan(days.count, 40)
    }

    func test_fuelPrice_fromMinistryNotice() throws {
        let text = try String(contentsOf: Fixtures.url("outside/fuel-october-2026.txt"), encoding: .utf8)
        XCTAssertEqual(OutsideParsers.fuelPrice95(fromText: text), 8.27)
        XCTAssertNil(OutsideParsers.fuelPrice95(fromText: "nothing here 1.23"))
    }

    func test_fuelPrice_urlsTryBothNamings() {
        let urls = OutsideParsers.fuelPriceURLs(month: "august", year: 2026).map(\.absoluteString)
        XCTAssertTrue(urls.contains("https://www.gov.il/BlobFolder/news/fuel-august-2026/he/fuel_august2026.pdf"))
        XCTAssertTrue(urls.contains("https://www.gov.il/BlobFolder/news/fuel-august-2026/he/fuel-august-2026.pdf"))
    }

    func test_requests_sendOnlyARoundedLocation() {
        let url = OutsideParsers.openMeteoForecastURL(lat: 10.0123, lon: -30.0291).absoluteString
        XCTAssertTrue(url.contains("latitude=10.02"), url)
        XCTAssertTrue(url.contains("longitude=-30.02"), url)
        XCTAssertTrue(OutsideParsers.metNorwayURL(lat: 10.0123, lon: -30.0291).absoluteString.contains("lat=10.02&lon=-30.02"))
    }

    func test_badResponsesAreFailures() {
        XCTAssertThrowsError(try OutsideParsers.openMeteoHourly(Data("not json".utf8)))
        XCTAssertThrowsError(try OutsideParsers.openMeteoHourly(Data("{\"hourly\":{\"time\":[\"2026-10-02T00:00\"],\"wind_speed_10m\":[900]}}".utf8)))
        XCTAssertThrowsError(try OutsideParsers.holidays(Data("{\"items\":[]}".utf8)))
    }
}
