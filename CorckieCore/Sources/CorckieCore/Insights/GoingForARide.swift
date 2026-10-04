import Foundation

/// M1-07 / M1-10: the "Going for a ride?" notification rules (CONCEPT "Message budget", M1_PLAN section 6 decision 6).
///
/// - One notification per power-on. A power-on ends at the scooter's 0x80 power-off flag or when the link has
///   been down for more than 2 minutes, so reconnect blips (B04) never send a second one.
/// - Sent before the wheel moves, with the battery in the title, only while the app is not on screen and no
///   ride is going (a ride shows live banners instead).
/// - Outside the message budget and quiet hours: no daily count, no 22:00-07:00 check.
/// - Removed when the ride starts (stage 1) or the scooter turns off (0x80, or the link gone for more than
///   2 min, which is what the ~5 min standing auto-off looks like from the phone).
/// - Every decision is logged for `message_log` (sent, or dropped with the reason).
///
/// The engine (M1-03 / M1-04) feeds the events; the notifier (`GoingForARideNotifier`) acts on the outputs.

public struct MessageLogEntry: Equatable, Sendable {
    public var type: String
    public var channel: String
    public var at: Double
    /// nil = sent
    public var droppedReason: String?

    public init(type: String, channel: String, at: Double, droppedReason: String?) {
        self.type = type
        self.channel = channel
        self.at = at
        self.droppedReason = droppedReason
    }
}

public enum GoingForARideOutput: Equatable, Sendable {
    case send(batteryPct: Int?)
    case remove(reason: String)
    case log(MessageLogEntry)
}

public struct GoingForARideRule: Equatable, Sendable {
    public static let messageType = "going_for_a_ride"
    /// A link down for longer than this ends the power-on
    public static let sessionGapS = 120.0
    /// The battery reading is awaited this long; then the notification goes out without it
    public static let batteryWaitS = 10.0

    private var sessionOpen = false
    private var settled = false            // sent or deliberately dropped for this power-on
    private var waitingSince: Double?      // connected, waiting for the first battery reading
    private var delivered = false          // the notification is on the phone right now
    private var disconnectedAt: Double?

    public init() {}

    public var isDelivered: Bool { delivered }

    // MARK: Events

    public mutating func scooterConnected(at t: Double, appActive: Bool, rideActive: Bool) -> [GoingForARideOutput] {
        var out = closeIfStale(at: t)
        disconnectedAt = nil
        if !sessionOpen {
            sessionOpen = true
            settled = false
            waitingSince = nil
        }
        guard !settled else { return out }
        if rideActive {
            out += drop(at: t, reason: "ride in progress")
        } else if appActive {
            out += drop(at: t, reason: "app on screen")
        } else if waitingSince == nil {
            waitingSince = t
        }
        return out
    }

    public mutating func batteryReading(pct: Double, at t: Double, appActive: Bool, rideActive: Bool) -> [GoingForARideOutput] {
        guard sessionOpen, !settled, waitingSince != nil else { return [] }
        if rideActive { return drop(at: t, reason: "ride in progress") }
        if appActive { return drop(at: t, reason: "app on screen") }
        return send(batteryPct: Int(pct.rounded()), at: t)
    }

    public mutating func scooterDisconnected(at t: Double) {
        if sessionOpen, disconnectedAt == nil { disconnectedAt = t }
    }

    /// The scooter says it is turning off (0x80 flag)
    public mutating func powerOff(at t: Double) -> [GoingForARideOutput] {
        endSession(reason: "scooter off")
    }

    /// Ride start stage 1: the notification has done its job
    public mutating func rideStarted(at t: Double) -> [GoingForARideOutput] {
        waitingSince = nil
        settled = true
        guard delivered else { return [] }
        delivered = false
        return [.remove(reason: "ride started")]
    }

    /// Call about once a second (or when the app wakes): ends a long disconnect, stops waiting for the battery.
    public mutating func tick(at t: Double, appActive: Bool, rideActive: Bool) -> [GoingForARideOutput] {
        var out = closeIfStale(at: t)
        if sessionOpen, !settled, disconnectedAt == nil, let since = waitingSince, t - since >= Self.batteryWaitS {
            if rideActive {
                out += drop(at: t, reason: "ride in progress")
            } else if appActive {
                out += drop(at: t, reason: "app on screen")
            } else {
                out += send(batteryPct: nil, at: t)
            }
        }
        return out
    }

    // MARK: Internals

    private mutating func closeIfStale(at t: Double) -> [GoingForARideOutput] {
        guard sessionOpen, let d = disconnectedAt, t - d > Self.sessionGapS else { return [] }
        return endSession(reason: "scooter off")
    }

    private mutating func endSession(reason: String) -> [GoingForARideOutput] {
        let wasDelivered = delivered
        sessionOpen = false
        settled = false
        waitingSince = nil
        disconnectedAt = nil
        delivered = false
        return wasDelivered ? [.remove(reason: reason)] : []
    }

    private mutating func send(batteryPct: Int?, at t: Double) -> [GoingForARideOutput] {
        settled = true
        waitingSince = nil
        delivered = true
        return [.send(batteryPct: batteryPct),
                .log(MessageLogEntry(type: Self.messageType, channel: "notification", at: t, droppedReason: nil))]
    }

    private mutating func drop(at t: Double, reason: String) -> [GoingForARideOutput] {
        settled = true
        waitingSince = nil
        return [.log(MessageLogEntry(type: Self.messageType, channel: "notification", at: t, droppedReason: reason))]
    }
}

// MARK: - Notifier (the actions; the App layer supplies the real notification centre and database)

public protocol NotificationSending {
    func send(id: String, title: String, body: String, soundName: String)
    func remove(id: String)
}

public protocol MessageLogging {
    func log(_ entry: MessageLogEntry)
}

public enum GoingForARideContent {
    public static let notificationID = "corckie.goingForARide"
    /// The owner's Kick-off chime (bundled WAV, B10 needs the sound permission)
    public static let soundName = "chime2_kickoff.wav"
    public static let body = "Going for a ride? Tap here"

    public static func title(batteryPct: Int?) -> String {
        guard let b = batteryPct else { return "Scooter on" }
        return "Scooter on · \(b)%"
    }
}

/// Applies the rule's outputs: notification centre + message log.
public final class GoingForARideNotifier {
    public private(set) var rule = GoingForARideRule()
    private let sender: NotificationSending
    private let logger: MessageLogging

    public init(sender: NotificationSending, logger: MessageLogging) {
        self.sender = sender
        self.logger = logger
    }

    public func scooterConnected(at t: Double, appActive: Bool, rideActive: Bool) {
        apply(rule.scooterConnected(at: t, appActive: appActive, rideActive: rideActive))
    }

    public func batteryReading(pct: Double, at t: Double, appActive: Bool, rideActive: Bool) {
        apply(rule.batteryReading(pct: pct, at: t, appActive: appActive, rideActive: rideActive))
    }

    public func scooterDisconnected(at t: Double) { rule.scooterDisconnected(at: t) }

    public func powerOff(at t: Double) { apply(rule.powerOff(at: t)) }

    public func rideStarted(at t: Double) { apply(rule.rideStarted(at: t)) }

    public func tick(at t: Double, appActive: Bool, rideActive: Bool) {
        apply(rule.tick(at: t, appActive: appActive, rideActive: rideActive))
    }

    private func apply(_ outputs: [GoingForARideOutput]) {
        for o in outputs {
            switch o {
            case .send(let pct):
                sender.send(id: GoingForARideContent.notificationID, title: GoingForARideContent.title(batteryPct: pct),
                            body: GoingForARideContent.body, soundName: GoingForARideContent.soundName)
            case .remove:
                sender.remove(id: GoingForARideContent.notificationID)
            case .log(let entry):
                logger.log(entry)
            }
        }
    }
}
