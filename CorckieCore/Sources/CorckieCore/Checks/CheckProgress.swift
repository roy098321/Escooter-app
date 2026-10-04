import Foundation

/// One line of a multi-step check's checklist (M1-00b): ticks itself when the step is detected.
public struct CheckStep: Equatable, Sendable {
    public let title: String
    public let done: Bool
    public init(_ title: String, done: Bool) {
        self.title = title
        self.done = done
    }
}

/// A progress bar with its words (M1-00b): time left on timed checks, "12 of 20" on counted ones.
public struct CheckBar: Equatable, Sendable {
    public let fraction: Double
    public let label: String
    public init(fraction: Double, label: String) {
        self.fraction = fraction
        self.label = label
    }
}

/// Pure logic behind the Checks screen's progress bars and step ticks, so Linux tests can pin it.
public enum CheckProgress {
    /// Timed check: "3:20 left" (or "done" once the time is up).
    public static func timed(elapsed: Double, total: Double) -> CheckBar {
        let e = min(max(elapsed, 0), total)
        let left = Int((total - e).rounded(.up))
        let label = left <= 0 ? "done" : String(format: "%d:%02d left", left / 60, left % 60)
        return CheckBar(fraction: total > 0 ? e / total : 1, label: label)
    }

    /// Counted check: "12 of 20 fixes".
    public static func counted(have: Int, need: Int, noun: String) -> CheckBar {
        let h = min(max(have, 0), need)
        return CheckBar(fraction: need > 0 ? Double(h) / Double(need) : 1, label: "\(h) of \(need) \(noun)")
    }

    /// Several short jobs one after another (Run all automatic, outside-data runs): "step 3 of 7".
    public static func stepped(index: Int, of count: Int, name: String) -> CheckBar {
        let i = min(max(index, 0), count)
        return CheckBar(fraction: count > 0 ? Double(max(i - 1, 0)) / Double(count) : 1, label: "Step \(i) of \(count) · \(name)")
    }

    /// "3 of 5" for the header of a step list.
    public static func tally(_ steps: [CheckStep]) -> String {
        "\(steps.filter(\.done).count) of \(steps.count)"
    }

    // MARK: Step lists (the owner's example: b9 armed · phone locked · disconnected · back · reconnected)

    public static func b9(armed: Bool, locked: Bool, disconnected: Bool, reconnected: Bool, withoutOpening: Bool) -> [CheckStep] {
        [CheckStep("Range test armed", done: armed),
         CheckStep("Phone locked", done: locked),
         CheckStep("Scooter disconnected (out of range)", done: disconnected),
         CheckStep("Back in range, reconnected", done: reconnected),
         CheckStep("Reconnected without opening the app", done: withoutOpening)]
    }

    public static func c5(restarted: Bool, startedInBackground: Bool, scooterConnected: Bool, passed: Bool) -> [CheckStep] {
        [CheckStep("Phone restarted", done: restarted),
         CheckStep("App started by itself (you didn't open it)", done: startedInBackground),
         CheckStep("Scooter connected in the background", done: scooterConnected),
         CheckStep("Counted as a wake before you opened the app", done: passed)]
    }

    public static func c6(scooterWoke: Bool, sent: Bool, delivered: Bool) -> [CheckStep] {
        [CheckStep("Scooter switched on, app in the background", done: scooterWoke),
         CheckStep("Notification sent", done: sent),
         CheckStep("Notification delivered (tap it too)", done: delivered)]
    }

    public static func c7(lowPower: Bool, woke: Bool, enoughData: Bool) -> [CheckStep] {
        [CheckStep("Low Power Mode on", done: lowPower),
         CheckStep("Scooter woke the app", done: woke),
         CheckStep("20+ packets and 5+ fixes while locked", done: enoughData)]
    }
}
