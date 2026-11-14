import XCTest
@testable import CorckieCore

/// Batch 5 (105.221126.00): guard tests for the source-level rules. Made-up data only.
final class Batch105Tests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// I1: the SideStore expiry notice and its notification are gone for everyone
    func test_I1_noExpiryNoticeOrNotification() throws {
        let edge = try source("App/Adapters/EdgeWatch.swift")
        XCTAssertFalse(edge.contains("AppExpiry.homeNotice("))
        XCTAssertFalse(edge.contains("schedule(plan)"))
        XCTAssertTrue(edge.contains("expiryNotice = nil"))
    }

    /// N5-2: no rider screen shows the thumbs row or the note card
    func test_N52_noTestingUIOnRiderScreens() throws {
        let riderFiles = ["App/UI/Rides/RideDetailView.swift", "App/UI/Home/HomeView.swift", "App/UI/Settings/SettingsView.swift",
                          "App/UI/Routes/RouteCardView.swift", "App/UI/Insights/InsightViews.swift"]
        for file in riderFiles {
            let text = try source(file)
            XCTAssertFalse(text.contains("ThumbsRow("), file)
            XCTAssertFalse(text.contains("RideNoteCard("), file)
            XCTAssertFalse(text.contains("ReportProblemView()"), "\(file): Report a problem lives in Developer")
        }
    }

    /// N5-4: Settings opens Developer through the password gate
    func test_N54_developerIsBehindTheGate() throws {
        let settings = try source("App/UI/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("DeveloperGateView()"))
        XCTAssertFalse(settings.contains("DeveloperView()"))
    }

    /// N5-3: the shrunk Developer tab keeps its short list
    func test_N53_developerKeepsOnlyTheShortList() throws {
        let dev = try source("App/UI/Developer/DeveloperView.swift")
        for gone in ["SensorsView()", "OutsideDataView()", "ReadabilityView()", "InsightsView()", "AccuracyView()",
                     "RideScreenPreview()", "V09PlayAllView()", "V09ReplayView()", "RouteLineLab()"] {
            XCTAssertFalse(dev.contains(gone), gone)
        }
        for kept in ["ChecksView()", "ResultsView()", "CrashView()", "BackupView()", "ScooterCheckView()", "SimulatorView()",
                     "ExportLogView()", "ReportProblemView()"] {
            XCTAssertTrue(dev.contains(kept), kept)
        }
    }

    /// C7 / K1 / K4 / K5: the approved wording
    func test_polishWording() {
        XCTAssertEqual(V09Message.pointOfNoReturn(metres: 300).line, "Last chance to turn back in three hundred metres.")
        XCTAssertEqual(V09Message.engineOverheating(c: 94).line, "Motor overheating, ninety four degrees.")
        XCTAssertEqual(QuickDial.minutesText(30), "30 min")
        XCTAssertFalse(QuickDial.estimateSeparator.contains("\u{2022}"))
    }

    /// T11: simulated rides stay out of the rider's Rides list and Home
    func test_T11_simulatedRidesStayOutOfRiderLists() throws {
        let list = try source("App/UI/Rides/RidesListView.swift")
        XCTAssertTrue(list.contains("!$0.isSimulated"))
        let home = try source("App/UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("!$0.isSimulated"))
    }

    /// 4c / 5c: a quiet line when alerts or Motion are refused, with a way to Settings
    func test_4c_5c_quietPermissionLines() throws {
        let home = try source("App/UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("Switch-on alerts are off."))
        XCTAssertTrue(home.contains("notificationsDenied"))
        let ride = try source("App/UI/Rides/RideDetailView.swift")
        XCTAssertTrue(ride.contains("motionDenied"))
        XCTAssertTrue(ride.contains("Allow Motion for better climbs."))
    }

    /// 4b: every alert has its own switch and the code that sends it checks the switch
    func test_4b_everyAlertHasASwitchThatIsChecked() throws {
        let store = try source("App/Recorder/SettingsStore.swift")
        for k in ["switchOn", "arriveBy", "charge", "weekly", "wind", "maintenance", "wear"] { XCTAssertTrue(store.contains(k), k) }
        XCTAssertTrue(try source("App/Notifier/Notifier.swift").contains(".switchOn"))
        XCTAssertTrue(try source("App/Charge/ChargeTimer.swift").contains(".charge"))
        XCTAssertTrue(try source("App/Charge/BatteryDecayService.swift").contains(".wear"))
        XCTAssertTrue(try source("App/UI/Settings/SettingsView.swift").contains("NotifyKind.alwaysOn"))
    }

    /// A2: Start fresh offers "Bring rider info back" and the copy never touches the scooter's settings
    func test_A2_bringRiderInfoBackExists() throws {
        XCTAssertTrue(try source("App/UI/Settings/StartFreshView.swift").contains("Bring rider info back"))
        let fresh = try source("App/Store/StartFresh.swift")
        XCTAssertTrue(fresh.contains("bringRiderInfoBack"))
        XCTAssertTrue(fresh.contains("DataMap.scooterSettingKeys"))
        XCTAssertFalse(fresh.contains("INSERT OR REPLACE INTO main.calibration"))
    }

    /// K3: one Prices screen, reached from Settings and from Stats
    func test_K3_onePricesScreen() throws {
        let prices = try source("App/UI/Settings/PricesView.swift")
        for part in ["FuelPriceView()", "CostSettingsView()", "PriceHistoryView()"] { XCTAssertTrue(prices.contains(part), part) }
        XCTAssertTrue(try source("App/UI/Settings/SettingsView.swift").contains("PricesView()"))
        XCTAssertTrue(try source("App/UI/Shared/Components.swift").contains("PricesView()"))
    }

    /// K2: Settings no longer has a second screen called just "Battery"
    func test_K2_settingsBatteryIsBatterySetup() throws {
        let s = try source("App/UI/Settings/SettingsView.swift")
        XCTAssertFalse(s.contains("navigationTitle(\"Battery\")"))
        XCTAssertTrue(s.contains("navigationTitle(\"Battery setup\")"))
    }

    /// I2: the charge-log info does not show the owner's charging speed
    func test_I2_noHardCodedChargingSpeedInBatteryInfo() throws {
        XCTAssertFalse(try source("App/UI/Battery/BatteryView.swift").contains("13.6 % per hour"))
    }

    /// K10 / I2 (P-6): no owner-specific tyre pressure shown to every rider
    func test_K10_noHardCodedTyrePressure() {
        let tyres = Maintenance.defaults(odoKm: 0, nowMs: 0).first { $0.id == "tyres" }
        XCTAssertNotNil(tyres)
        XCTAssertFalse(tyres?.hint.contains("PSI") ?? true)
    }

    /// C2: chart titles say what it means on the road
    func test_C2_chartTitlesUseRangeWords() throws {
        for file in ["CreepInsight", "SweetSpotInsight", "WindTodayInsight"] {
            let text = try source("CorckieCore/Sources/CorckieCore/Insights/F21/\(file).swift")
            XCTAssertFalse(text.contains("Your rides, battery per km"), file)
        }
    }
}
