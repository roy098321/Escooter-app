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
        XCTAssertTrue(root.contains(".fullScreenCover(isPresented: .constant(liveCoverShown || summaryShown))"),
                      "the live view is a full-screen cover that nothing but the ride state can close")
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
        XCTAssertTrue(live.contains("if tappable && !s.bannerIsSameRide"), "a banner tap needs the tappable flag")
    }

    func test_closeButtonOnlyInReady() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        guard let range = live.range(of: "closeReady()") else { return XCTFail("closeReady missing") }
        XCTAssertTrue(live[..<range.lowerBound].suffix(600).contains("if s.canClose"), "Close exists only where canClose is true (Ready)")
    }
}
