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
