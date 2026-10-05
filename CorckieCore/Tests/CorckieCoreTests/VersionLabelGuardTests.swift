import XCTest

/// Owner, P4_DILEMMAS D3: "v1" is visible on every screen. Runs on Linux CI against the app's
/// source text, so a new sheet or full-screen cover without the label fails the build.
final class VersionLabelGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    /// M1-01: the milestone version is 0.6 (bumped per milestone: M2 → 0.6, M3 → 0.7 …), and the label reads it from the bundle.
    func test_M2_01_versionIs06() throws {
        let yml = try String(contentsOf: appFolder.deletingLastPathComponent().appendingPathComponent("project.yml"), encoding: .utf8)
        let line = yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION") } ?? ""
        XCTAssertTrue(line.contains("\"0.6\""), "project.yml MARKETING_VERSION must be 0.6 for M2: \(line)")
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("CFBundleShortVersionString"))
    }

    func test_D3_rootAppliesTheLabel() throws {
        XCTAssertTrue(try text("UI/RootView.swift").contains(".v1Label()"), "RootView must apply .v1Label() to the whole app")
        XCTAssertTrue(try text("UI/Shared/VersionLabel.swift").contains("AppInfo.v1Line"))
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("productVersion = \"v1\""))
    }

    func test_D3_everySheetAndCoverCarriesTheLabel() throws {
        guard let walker = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil) else {
            return XCTFail("App folder not found")
        }
        for case let file as URL in walker where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let presents = [".sheet(", ".fullScreenCover(", ".popover("].filter { source.contains($0) }
            if !presents.isEmpty {
                XCTAssertTrue(source.contains(".v1Label()"),
                              "\(file.lastPathComponent) presents \(presents.joined(separator: ", ")) without .v1Label()")
            }
        }
    }
}
