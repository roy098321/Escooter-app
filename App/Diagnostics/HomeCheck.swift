import CorckieCore
import Foundation

/// u13 (M1-11): the Home states and the connect rules; o1: onboarding in 3 presses. Both run the pure rules of
/// CorckieCore on made-up inputs (no scooter, nothing stored).
enum HomeCheck {
    static func run() {
        runHome()
        runOnboarding()
    }

    private static func runHome() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        let now = Date().timeIntervalSince1970
        func input(paired: Bool, connected: Bool, since: Double? = nil, ride: Bool = false) -> HomeInput {
            HomeInput(paired: paired, connected: connected, connectingSinceS: since, nowS: now, batteryPct: 91,
                      lastSeenMs: Int64((now - 7200) * 1000), lastSeenPct: 58, rideActive: ride)
        }
        let first = HomeLogic.model(input(paired: false, connected: false))
        expect(first.state == .noScooter && first.primary == .connect, "first use: Connect your scooter")
        let away = HomeLogic.model(input(paired: true, connected: false))
        expect(away.primary == .connect && away.greyed && away.detail.hasPrefix("last seen"), "not connected: greyed, last seen, no Start ride")
        expect(HomeLogic.model(input(paired: true, connected: true)).primary == .startRide, "connected: Start ride")
        expect(HomeLogic.model(input(paired: true, connected: false, since: now - 31)).state == .cantFind, "connect fails after 30 s")
        expect(HomeLogic.model(input(paired: true, connected: false, since: now - 20)).state == .connecting, "still connecting at 20 s")
        expect(HomeLogic.model(input(paired: true, connected: true, ride: true)).state == .riding, "ride in progress")
        CheckResults.shared.set("u13", ok ? .pass : .fail, notes.joined(separator: " \u{00B7} "))
    }

    private static func runOnboarding() {
        // keep a real run's result (the owner's own pass through the screens)
        if CheckResults.shared.note("o1").hasPrefix("Real run") { return }
        var flow = OnboardingFlow(scooterFound: true)
        flow.press(.connect)
        flow.press(.allow)
        flow.press(.notNow)
        let ok = flow.isDone && flow.presses == 3
        CheckResults.shared.set("o1", ok ? .pass : .fail,
                                "Rules: \(flow.presses) presses to Done (connect, allow, allow / not now). Developer \u{2192} Show onboarding runs the real screens and records the result here")
    }
}
