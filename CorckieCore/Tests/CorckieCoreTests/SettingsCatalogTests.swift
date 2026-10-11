import XCTest
@testable import CorckieCore

/// M5-06: the Settings list is the C23 list, in its order, with the defaults the app really uses.
final class SettingsCatalogTests: XCTestCase {
    func testGroupsAreTheC23ListInOrder() {
        XCTAssertEqual(SettingsCatalog.groups.map(\.title),
                       ["Battery and charging", "Units and display", "Costs", "Rider", "Voice and notifications", "Places", "Data and backup", "Help", "Developer"])
        let rows = SettingsCatalog.groups.map { $0.rows.map(\.title) }
        XCTAssertEqual(rows[0], ["Battery size", "Charger", "Recalibrate battery"])
        XCTAssertEqual(rows[1], ["Sunlight mode", "Units", "Colour-blind friendly speed colours"])
        XCTAssertEqual(rows[2], ["Electricity price", "Car fuel use", "Fuel price"])
        XCTAssertEqual(rows[3], ["Rider weight", "Load levels"])
        XCTAssertEqual(rows[4], ["Weekly summary (Sun 7:30)", "Wind picking up", "Arrive-by reminders", "Maintenance due"])
        XCTAssertEqual(rows[5], ["Places"])
        XCTAssertEqual(rows[6], ["Keep raw data", "Backup folder \u{00B7} Last backup", "Restore", "Export everything", "Delete all data"])
        XCTAssertEqual(rows[7], ["Report a problem"])
        XCTAssertEqual(rows[8], ["Developer"])
    }

    func testDefaultsAreTheRealConstants() {
        XCTAssertEqual(SettingsCatalog.row("battery.packAh")?.defaultText, "16 Ah")
        XCTAssertEqual(T.t42DefaultPackAh, 16)
        XCTAssertEqual(SettingsCatalog.row("battery.chargerA")?.defaultText, "2.0 A")
        XCTAssertEqual(T.t46ChargerA, 2.0)
        XCTAssertEqual(SettingsCatalog.row("display.sunlight")?.defaultText, "Auto")
        XCTAssertEqual(SettingsCatalog.row("display.colourBlind")?.defaultText, "Off")
        XCTAssertEqual(SettingsCatalog.row("stats.electricity")?.defaultText, "\u{20AA}0.64 / kWh")
        XCTAssertEqual(SettingsCatalog.row("stats.fuelUse")?.defaultText, "7 L / 100 km")
        XCTAssertEqual(SettingsCatalog.row("rider.weightKg")?.defaultText, "Not set")
        XCTAssertEqual(SettingsCatalog.row("rider.loads")?.defaultText, "Light 5 kg \u{00B7} Heavy 15 kg")
        XCTAssertEqual(SettingsCatalog.row("data.rawRetention")?.defaultText, "90 days")
        for id in ["notify.weekly", "notify.wind", "notify.arriveBy", "notify.maintenance"] { XCTAssertEqual(SettingsCatalog.row(id)?.defaultText, "On") }
    }

    func testChoicesIncludeTheDefaults() {
        XCTAssertTrue(SettingsCatalog.chargerChoices.contains(T.t46ChargerA))
        XCTAssertTrue(SettingsCatalog.packChoices.contains(T.t42DefaultPackAh))
        XCTAssertTrue(SettingsCatalog.packChoices.contains(13))
    }

    func testEveryRowHasAUniqueId() {
        let ids = SettingsCatalog.groups.flatMap(\.rows).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ids.count, 23)
    }
}
