import XCTest

/// P6-2 chunk 3 (ST1-ST13, B1-B5, S1-S5, T1-T5, K1-K4, P1-P3, SE1-SE9, E1-E4, O1): the sentences the owner approved for deletion stay
/// gone from the Stats, Battery, Scooter, Routes, Places, Settings, Export / Restore and Onboarding source text.
final class DeclutterStatsGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    private func assertGone(_ path: String, _ strings: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try text(path)
        for s in strings { XCTAssertFalse(source.contains(s), "\(path) still has: \(s)", file: file, line: line) }
    }

    func test_statsSentencesAreGone() throws {
        try assertGone("UI/Stats/StatsView.swift", ["Weekly summary", "Totals, charges and costs", "Insights appear after rides", "StatsMode.allCases",
                                                    "against the same point", "A later price never changes", "Used for the electricity"])
        try assertGone("Recorder/StatsLoader.swift", ["of the battery used", "L/100 km\"", "against the same point"])
        try assertGone("Recorder/OverallLoader.swift", ["scooter odometer\"", "logged rides\"", "estimate, from the purchase date", "of petrol\""])
        let stats = try text("UI/Stats/StatsView.swift")
        XCTAssertTrue(stats.contains("StatsSpan.allCases"))
        XCTAssertTrue(stats.contains("SectionHeader(\"Money\")"))
        XCTAssertTrue(stats.contains("SectionHeader(\"Overall\")"))
        // F-21: the old Recent insights list is replaced by the Insights cards (at most 3, Medium / High only)
        XCTAssertFalse(stats.contains("Recent insights"))
        XCTAssertTrue(stats.contains("InsightsSection(board: m.insights)"))
        let insights = try text("UI/Insights/InsightViews.swift")
        XCTAssertTrue(insights.contains("SectionHeader(\"Insights\")"))
        for gone in ["lightbulb", "Peak ", "Ride the same trip"] { XCTAssertFalse(insights.contains(gone), "Insights must not contain \(gone)") }
    }

    func test_factorsSentencesAreGone() throws {
        try assertGone("UI/Stats/FactorsView.swift", ["What each factor costs on every route together", "per trip.\")", "Uncertain: outside what physics allows",
                                                      "if let n = row.basedOn { Text"])
    }

    func test_batterySentencesAreGone() throws {
        try assertGone("UI/Battery/BatteryView.swift", ["Reserve kept", "With the 10% safety margin", "when last seen)", "About 2 A", "Full from now",
                                                        "The range above is the honest number", "It starts from the 16 Ah pack", "Battery data is not available yet"])
    }

    func test_scooterSentencesAreGone() throws {
        try assertGone("UI/Scooter/ScooterTabView.swift", ["Tyres, brakes and bolts", "Open maintenance", "Removes the pairing only", "km total",
                                                           "found again by itself", "Last seen \\("])
    }

    func test_routesSentencesAreGone() throws {
        try assertGone("UI/Routes/RoutesListView.swift", ["Trips you rode more than once", "Greyed routes need more battery", "header(\"Places\")",
                                                          "header(\"Routes\")", "Ride the same trip twice", "r.summary"])
        try assertGone("UI/Routes/RouteCardView.swift", ["Saved route", "From the phone's barometer", "rides in all", "m.map.count) variants",
                                                         "You have ridden this same trip more than once", "s.note"])
        try assertGone("UI/Routes/PlaceMapView.swift", ["place.row.subtitle", "Toggle(\"I can charge here\""])
    }

    func test_settingsSentencesAreGone() throws {
        try assertGone("UI/Settings/SettingsView.swift", ["Units", "App ID", "Light and Heavy are what", "Checks, results and the test tools", "Keep raw data",
                                                          "ImportRideLogsView", "footer(", "Optional."])
        let settings = try text("UI/Settings/SettingsView.swift")
        for group in ["Scooter & battery", "Rider & load", "Costs", "Places", "Data & backup"] {
            XCTAssertTrue(settings.contains("group(\"\(group)\")"), "Settings group missing: \(group)")
        }
        let developer = try text("UI/Developer/DeveloperView.swift")
        XCTAssertTrue(developer.contains("DeveloperDataRows()"))
        try assertGone("UI/Settings/DataSettingsViews.swift", ["Everything stays on this phone unless", "One file with every ride and all its readings",
                                                               "full-....corckie"])
        try assertGone("UI/Settings/PriceHistoryView.swift", ["Israel sets it on the 1st", "earlier rides keep the rate they had", "spread evenly over the days"])
        try assertGone("UI/Settings/MaintenanceView.swift", ["Counted in scooter kilometres. You get one reminder"])
        try assertGone("UI/Settings/ReportProblemView.swift", ["One .zip with the last 15 minutes"])
        try assertGone("OutsideData/FuelPriceSetting.swift", ["comes back in v2"])
        try assertGone("UI/Rides/RideToolsSheets.swift", ["Nothing is deleted. The ride keeps all its readings"])
        let purchase = try text("UI/Settings/PriceHistoryView.swift")
        XCTAssertTrue(purchase.contains("Odometer at purchase"))
    }

    func test_onboardingAndRidesLeftoversAreGone() throws {
        try assertGone("UI/Onboarding/OnboardingView.swift", ["Looking for your scooter", "Allow location (choose Always)", "At most 2 notifications a day",
                                                              "Found your scooter", "Weekly summary and reminders"])
        let rides = try text("UI/Rides/RidesListView.swift")
        XCTAssertTrue(rides.contains("elsewhere"))
    }
}
