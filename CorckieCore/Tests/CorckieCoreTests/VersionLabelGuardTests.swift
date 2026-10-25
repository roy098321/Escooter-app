import XCTest
@testable import CorckieCore

/// Owner, P4_DILEMMAS D3 + G4 (P6-2): the "v1" tag shows in Settings → About only. Runs on Linux CI against the app's
/// source text, so a screen that shows the tag again fails the build.
final class VersionLabelGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    /// F-30b (replaces the M1-01 1.0 freeze): the version is the release name VB.DDMMYY.HH ("101.251026.00"), and the label reads it
    /// from the bundle. The batch number leads, so the name always increases for Apple.
    func test_M2_01_versionIs10() throws {
        let yml = try String(contentsOf: appFolder.deletingLastPathComponent().appendingPathComponent("project.yml"), encoding: .utf8)
        let line = yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION") } ?? ""
        let value = line.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
        XCTAssertTrue(ReleaseName.isValid(value), "project.yml MARKETING_VERSION must be a release name VB.DDMMYY.HH:\(line)")
        XCTAssertGreaterThanOrEqual(Int(value.prefix(3)) ?? 0, 101)
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("CFBundleShortVersionString"))
    }

    /// G4 (P6-2): the version tag is shown in Settings → About only, no longer on every screen or the live view
    func test_G4_versionTagOnlyInAbout() throws {
        XCTAssertTrue(try text("UI/Shared/VersionLabel.swift").contains("AppInfo.v1Line"))
        let settings = try text("UI/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("productVersion = \"v1\""))
        XCTAssertTrue(settings.contains("LabeledContent(\"Version\") { VersionLabel() }"), "Settings → About shows the version tag")
        XCTAssertFalse(try text("UI/RootView.swift").contains(".v1Label()"), "the tag is no longer applied to the whole app")
    }

    func test_G4_noOtherScreenShowsTheTag() throws {
        guard let walker = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil) else {
            return XCTFail("App folder not found")
        }
        for case let file as URL in walker where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(".v1Label()"), "\(name) still puts the version tag on a screen (G4: About only)")
            if name != "SettingsView.swift" && name != "VersionLabel.swift" {
                XCTAssertFalse(source.contains("VersionLabel()") || source.contains("AppInfo.v1Line"), "\(name) shows the version tag (G4: About only)")
            }
        }
    }
}
