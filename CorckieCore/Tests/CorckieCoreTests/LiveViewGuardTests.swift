import XCTest

/// M1-12 safety rules for the live ride screen, checked against the app's source text on Linux CI (like the v1 label
/// guard): no tabs, no navigation and no swipe-down while riding, and the ride ends only by the held stop button.
final class LiveViewGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    func test_liveViewHasNoTabsNoNavigationNoToolbar() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        for banned in ["TabView", "NavigationStack", "NavigationLink", ".toolbar", ".sheet(", "dismiss()"] {
            XCTAssertFalse(live.contains(banned), "the live view must not contain \(banned)")
        }
    }

    func test_liveViewCannotBeSwipedAwayAndSitsOverTheTabs() throws {
        XCTAssertTrue(try text("UI/Live/LiveRideView.swift").contains(".interactiveDismissDisabled(true)"))
        let root = try text("UI/RootView.swift")
        // M1-13: the same cover turns into the ride summary once the ride is over (it has a Done button)
        XCTAssertTrue(root.contains(".fullScreenCover(isPresented: Binding(get: { coverShown }, set: { _ in }))") && root.contains("coverShown = shown"),
                      "the live view is a full-screen cover that nothing but the ride state can close (A3: the binding ignores sets, onChange of the ride state drives it)")
        XCTAssertTrue(root.contains("service.rideActive || service.readyRequested"), "the live view shows while a ride or Ready is on")
        XCTAssertTrue(root.contains("LiveRideView()"))
    }

    func test_theRideEndsOnlyThroughTheHeldButton() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        let ends = live.components(separatedBy: "press(.endHeld)").count - 1
        XCTAssertEqual(ends, 1, "exactly one place ends a ride")
        // that place is the hold timer, not a Button action
        guard let range = live.range(of: "press(.endHeld)") else { return XCTFail("endHeld missing") }
        let before = String(live[..<range.lowerBound])
        let tail = before.suffix(300)
        XCTAssertTrue(tail.contains("hold.completed(at: now)"), "ending is gated by HoldToEnd.completed")
        XCTAssertFalse(tail.contains("Button("), "a plain button must never end the ride")
    }

    func test_bannersAreTappedOnlyThroughTheSpeedGate() throws {
        let service = try text("Adapters/RecorderService.swift")
        XCTAssertTrue(service.contains("driver.tapBanner(speedKmh: speed)"), "banner taps go through BannerQueue's 5 km/h gate")
        let live = try text("UI/Live/LiveRideView.swift")
        XCTAssertTrue(live.contains("if tappable { RecorderService.shared.tapBanner() }"), "a banner tap needs the tappable flag")
    }

    func test_closeButtonOnlyInReady() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        guard let range = live.range(of: "closeReady()") else { return XCTFail("closeReady missing") }
        XCTAssertTrue(live[..<range.lowerBound].suffix(600).contains("if s.canClose"), "Close exists only where canClose is true (Ready)")
    }

    /// B21: the live numbers keep their safe sizes (speed 76 pt, battery and ride time 60 pt, banners 17 pt) and the tiles are drawn from them
    func test_liveNumbersKeepTheirSafeSizes() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        func constant(_ name: String) -> Int? {
            guard let r = live.range(of: "static let \(name): CGFloat = ") else { return nil }
            return Int(live[r.upperBound...].prefix(while: { $0.isNumber }))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(constant("speedPt")), 76)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(constant("tilePt")), 60)
        XCTAssertTrue(live.contains("size: Self.speedPt"), "the speed number uses speedPt")
        XCTAssertEqual(live.components(separatedBy: "size: Self.tilePt").count - 1, 1, "battery and ride time share one small tile (same font)")
        XCTAssertTrue(live.contains("batteryTile(s)") && live.contains("clockTile(s)"))
        XCTAssertTrue(live.contains("banner(s, text)") && live.contains(".font(.title3.weight(.semibold))"), "banners stay at title3 (20 pt, above 17)")
    }

    private func core(_ path: String) throws -> String {
        try String(contentsOf: appFolder.deletingLastPathComponent().appendingPathComponent("CorckieCore/Sources/CorckieCore/" + path), encoding: .utf8)
    }

    /// P-4 (owner, 19 Oct): the rider is not interrupted. No SLOW, no live insights, no "Same ride?", no prompts, no choice-point
    /// prompts in the live view; the motor-hot banner stays and the only place that raises anything is `LiveAlerts`.
    func test_P4_liveViewIsQuiet() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        for gone in ["SLOW", ".slow", "slowText", "bannerIsSameRide", "answerSameRide", "Same ride", "Button(\"Yes\")", "choicePoint", "returnWarning"] {
            XCTAssertFalse(live.contains(gone), "the live view must not contain \(gone)")
        }
        let service = try text("Adapters/RecorderService.swift")
        for gone in ["answerSameRide", "returnWarning:", "prompts:", "FastestService.prompter", "promptsShownNow"] {
            XCTAssertFalse(service.contains(gone), "RecorderService must not contain \(gone)")
        }
        let screen = try core("Ride/LiveScreen.swift")
        for gone in ["choicePoint", "sameRide", "returnWarning", "prompter", "ChoicePrompt", ".slow", "SpeedWarning"] {
            XCTAssertFalse(screen.contains(gone), "the live screen driver must not contain \(gone)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: appFolder.deletingLastPathComponent()
            .appendingPathComponent("CorckieCore/Sources/CorckieCore/Ride/SpeedWarning.swift").path), "SpeedWarning is deleted")
        XCTAssertTrue(screen.contains("LiveAlerts.feed(&banners"), "the driver raises banners only through LiveAlerts")
        let alerts = try core("Ride/LiveWarnings.swift")
        let kinds = alerts.components(separatedBy: "public enum LiveAlertKind")[1].components(separatedBy: "public enum LiveAlert:")[0]
        XCTAssertEqual(kinds.components(separatedBy: "\n").filter { $0.hasPrefix("    case ") }.count, 3, "three kinds of interruption: battery, destination, motorHot")
        XCTAssertTrue(alerts.contains("case battery(level: Int, kmLeft: Int?)") && alerts.contains("case motorHot"))
        XCTAssertTrue(live.contains("Hold to end") && live.contains("a.short") && live.contains("batteryTile(s)"), "numbers, arrival chip and hold-to-end stay")
    }
}
