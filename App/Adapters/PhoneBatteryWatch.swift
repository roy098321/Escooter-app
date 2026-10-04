import CorckieCore
import Foundation
import UIKit

/// M1-16 (check q1): the phone's battery level at the start and the end of a ride, judged with `PhoneBatteryUse`
/// (at most 10% per 30 min of riding, rides of 15 min or more). Main thread only. Read-only: it never touches the scooter.
final class PhoneBatteryWatch {
    static let shared = PhoneBatteryWatch()

    private var startPct: Double?
    private var startAt: Date?

    private init() {}

    func enable() { UIDevice.current.isBatteryMonitoringEnabled = true }

    private func level() -> Double? {
        enable()
        let l = UIDevice.current.batteryLevel
        return l < 0 ? nil : Double(l) * 100
    }

    /// A ride started (a cancelled start is simply overwritten by the next one).
    func rideStarted() {
        startAt = Date()
        startPct = level()
    }

    /// The ride was closed: judge it when it lasted 15 min or more and the phone was not charging.
    func rideEnded() {
        guard let began = startAt else { return }
        let rideS = Date().timeIntervalSince(began)
        let a = startPct
        let b = level()
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        startAt = nil
        startPct = nil
        guard rideS >= PhoneBatteryUse.minRideS else { return }
        guard !charging else {
            CheckResults.shared.set("q1", .info, "Not judged: the phone was charging")
            return
        }
        guard let per30 = PhoneBatteryUse.per30Min(startPct: a, endPct: b, rideS: rideS), let a, let b else {
            CheckResults.shared.set("q1", .info, "Not judged: the phone's battery level was not available")
            return
        }
        let note = String(format: "%.1f%% per 30 min of riding (%.0f%% to %.0f%% over %d min)", per30, a, b, Int((rideS / 60).rounded()))
        CheckResults.shared.set("q1", PhoneBatteryUse.withinLimit(per30) ? .pass : .fail, note)
    }
}
