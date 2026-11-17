import XCTest

/// Batch 7 guards, checked against the app's source text on Linux CI (like ThemeGuardTests).
final class Batch107GuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    private func allSwift() -> [(String, String)] {
        let e = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.lastPathComponent, s))
        }
        return out
    }

    /// N7-8: one rule, all haptics through `Haptics` (so the Vibration switch mutes every one), a light tap on every switch,
    /// the ride warnings keep their taps, no haptic on deletes.
    func test_N7_8_oneHapticRule_andTheVibrationSwitch() throws {
        for (name, source) in allSwift() {
            XCTAssertFalse(source.contains(".sensoryFeedback("), "\(name) bypasses Haptics (the Vibration switch could not mute it)")
            XCTAssertFalse(source.contains("UIImpactFeedbackGenerator") && name != "DesignSystem.swift", "\(name) uses a generator directly")
        }
        let ds = try text("UI/Shared/DesignSystem.swift")
        XCTAssertTrue(ds.contains("static var muted: Bool"))
        XCTAssertEqual(ds.components(separatedBy: "guard !muted").count - 1, 8, "every Haptics call checks the switch")
        XCTAssertTrue(try text("UI/RootView.swift").contains(".toggleStyle(HapticSwitchStyle())"))
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("Toggle(\"Vibration\""))
        XCTAssertTrue(try text("Audio/SoundPlayer.swift").contains("Haptics.taps("), "ride warnings keep their vibration")
        XCTAssertFalse(try text("UI/Rides/RideDetailView.swift").contains("Haptics.warning()"), "no haptic on delete")
    }
}
