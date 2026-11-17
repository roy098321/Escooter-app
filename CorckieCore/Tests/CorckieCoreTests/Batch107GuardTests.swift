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

    /// N7-2: Liquid Glass only behind #available(iOS 26) in one place; sunlight and Reduce Transparency switch it off; the selected
    /// tab keeps its solid orange pill; glass on the floating controls and Live tiles only.
    func test_N7_2_liquidGlassIsGatedAndScoped() throws {
        let lg = try text("UI/Shared/LiquidGlass.swift")
        XCTAssertTrue(lg.contains("#available(iOS 26.0, *)") && lg.contains("guard !sunlight, !reduceTransparency"))
        for (name, source) in allSwift() where name != "LiquidGlass.swift" {
            XCTAssertFalse(source.contains(".glassEffect("), "\(name) uses glass outside the gate")
        }
        let bar = try text("UI/Shared/FloatingTabBar.swift")
        XCTAssertTrue(bar.contains(".liquidGlass(in: Capsule()") && bar.contains("Capsule().fill(Theme.accent)"))
        for file in ["UI/Shared/MapScreen.swift", "UI/Shared/GlassCard.swift", "UI/Shared/DesignSystem.swift"] {
            XCTAssertTrue(try text(file).contains(".liquidGlass(in:"), "\(file) has no glass")
        }
        XCTAssertFalse(try text("UI/Stats/StatsView.swift").contains(".liquidGlass("), "no glass on plain-page cards")
    }

    /// N7-3 / N7-13: zoom only on iOS 18 with the slide on iOS 17; scroll cards off with Reduce Motion
    func test_N7_3_N7_13_motionFallbacks() throws {
        let zoom = try text("UI/Shared/ZoomTransition.swift")
        XCTAssertEqual(zoom.components(separatedBy: "#available(iOS 18.0, *)").count - 1, 2)
        for file in ["UI/Rides/RidesListView.swift", "UI/Routes/RoutesListView.swift", "UI/Routes/PlacesView.swift"] {
            let s = try text(file)
            XCTAssertTrue(s.contains(".zoomSource(") && s.contains(".zoomDestination(") && s.contains(".scrollReactive()"), file)
        }
        let edge = try text("UI/Shared/EdgeEffects.swift")
        XCTAssertTrue(edge.contains("if reduceMotion {") && edge.contains(".scrollTransition("), "scroll cards stay still with Reduce Motion")
    }

    /// N7-5: icon moments move once on a real change, nothing with Reduce Motion; the motor-hot wiggle is one reusable modifier
    func test_N7_5_iconMomentsRespectReduceMotion() throws {
        let m = try text("UI/Shared/SymbolMoments.swift")
        XCTAssertEqual(m.components(separatedBy: "accessibilityReduceMotion").count - 1, 2)
        XCTAssertTrue(m.contains("func motorHotWiggle"))
        XCTAssertTrue(try text("UI/Live/LiveRideView.swift").contains(".motorHotWiggle("))
        XCTAssertTrue(try text("UI/Shared/FloatingTabBar.swift").contains(".bounceOnce(on)"))
    }

    /// N7-12: every sound kind has its file; one warning sound for battery, destination and motor; the new sounds sit behind
    /// the "Charging and saving" switch; the replay sound lasts as long as the route draws.
    func test_N7_12_soundFamily() throws {
        let sounds = appFolder.appendingPathComponent("Resources/Sounds")
        for name in ["connect", "ride_start", "ride_start_short", "ride_replay", "ride_end", "arrival", "plugged_in", "charge_full",
                     "saved", "battery_ping", "destination_ping", "motor_ping"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sounds.appendingPathComponent("\(name).wav").path), name)
        }
        let ping = try Data(contentsOf: sounds.appendingPathComponent("battery_ping.wav"))
        XCTAssertEqual(ping, try Data(contentsOf: sounds.appendingPathComponent("destination_ping.wav")), "one warning sound")
        XCTAssertEqual(ping, try Data(contentsOf: sounds.appendingPathComponent("motor_ping.wav")), "one warning sound")
        let player = try text("Audio/SoundPlayer.swift")
        XCTAssertTrue(player.contains("case .pluggedIn, .chargeFull, .saved: return .chargingSaving"))
        XCTAssertTrue(player.contains("\"Charging and saving\""))
    }

    /// N7-1 / N7-9: one set of ride intents shared by the island and the controls; no alerts in the island (P-4); Next never by time
    func test_N7_1_scooterIslandIsQuiet_andIntentsAreShared() throws {
        let shared = appFolder.deletingLastPathComponent().appendingPathComponent("Shared/RideActivity")
        let intents = try String(contentsOf: shared.appendingPathComponent("RideIntents.swift"), encoding: .utf8)
        XCTAssertTrue(intents.contains("struct StartRideIntent: LiveActivityIntent"))
        let attrs = try String(contentsOf: shared.appendingPathComponent("ScooterActivityAttributes.swift"), encoding: .utf8)
        for word in ["alert", "warning", "hot"] {
            XCTAssertFalse(attrs.lowercased().contains("var \(word)"), "no mid-ride alert state in the island")
        }
        let controller = try text("Adapters/ScooterActivityController.swift")
        XCTAssertTrue(controller.contains("static let readyS: TimeInterval = 120"))
        XCTAssertFalse(controller.contains("hour") || controller.contains("weekday") || controller.contains("Calendar"),
                       "Next never picks by time")
    }
}
