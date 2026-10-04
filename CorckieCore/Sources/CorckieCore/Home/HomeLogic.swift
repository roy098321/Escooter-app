import Foundation

// M1-11: what the Home tab shows, pure (STATES S1 / S2 + the connect rules, CONCEPT C27). The screen builds one
// `HomeInput` from the app (scooter link, recorder, settings) and shows the `HomeModel` that comes back.
// Rules: no ride can start before the scooter connection is confirmed, so "Start ride" exists only when connected;
// not connected shows "Connect your scooter" (never "off": the app cannot tell off from out of range); the status
// card of a paired but absent scooter is greyed and timestamped (pattern L); a connect attempt that has not
// succeeded after 30 s says "Can't find the scooter" with Try again.

public enum HomeState: String, Equatable, Sendable {
    /// Never paired (first use)
    case noScooter
    /// Paired, link down
    case notConnected
    /// Connect pressed, waiting (under 30 s)
    case connecting
    /// Connect pressed, nothing after 30 s
    case cantFind
    /// Connected, standing
    case ready
    /// A ride is on
    case riding
}

public enum HomePrimary: String, Equatable, Sendable {
    /// Amber "Connect your scooter" (first use: opens the onboarding)
    case connect
    case startRide
    case tryAgain
    /// "Open live view" while a ride is on
    case openRide
}

public struct HomeInput: Equatable, Sendable {
    public var paired: Bool
    public var connected: Bool
    /// Epoch seconds when Connect / Try again was pressed (nil = no attempt running)
    public var connectingSinceS: Double?
    public var nowS: Double
    /// Scooter battery now (connected) in percent
    public var batteryPct: Int?
    public var lastSeenMs: Int64?
    public var lastSeenPct: Int?
    public var utcOffsetMin: Int
    public var rideActive: Bool
    public var locationAlways: Bool
    public var lastRunCrashed: Bool
    public var lastRide: RideListItem?

    public init(paired: Bool, connected: Bool, connectingSinceS: Double? = nil, nowS: Double, batteryPct: Int? = nil,
                lastSeenMs: Int64? = nil, lastSeenPct: Int? = nil, utcOffsetMin: Int = 0, rideActive: Bool = false,
                locationAlways: Bool = true, lastRunCrashed: Bool = false, lastRide: RideListItem? = nil) {
        self.paired = paired
        self.connected = connected
        self.connectingSinceS = connectingSinceS
        self.nowS = nowS
        self.batteryPct = batteryPct
        self.lastSeenMs = lastSeenMs
        self.lastSeenPct = lastSeenPct
        self.utcOffsetMin = utcOffsetMin
        self.rideActive = rideActive
        self.locationAlways = locationAlways
        self.lastRunCrashed = lastRunCrashed
        self.lastRide = lastRide
    }
}

public struct HomeModel: Equatable, Sendable {
    public var state: HomeState
    public var title: String
    public var detail: String
    /// "91%" when connected, nil otherwise
    public var batteryText: String?
    /// Pattern L: values greyed
    public var greyed: Bool
    public var primary: HomePrimary
    public var primaryTitle: String
    public var primaryEnabled: Bool
    /// "Location is not set to Always" card (only once a scooter is paired)
    public var showLocationCard: Bool
    public var showCrashBanner: Bool
    /// "Last ride · 6.1 km · 18 min", nil without a ride
    public var lastRideText: String?
}

public enum HomeLogic {
    public static let connectFailsAfterS = 30.0

    public static func model(_ i: HomeInput) -> HomeModel {
        let state: HomeState
        if i.rideActive {
            state = .riding
        } else if i.connected {
            state = .ready
        } else if !i.paired {
            state = .noScooter
        } else if let since = i.connectingSinceS {
            state = i.nowS - since >= connectFailsAfterS ? .cantFind : .connecting
        } else {
            state = .notConnected
        }

        var title = ""
        var detail = ""
        var battery: String?
        var grey = false
        var primary = HomePrimary.connect
        var primaryTitle = "Connect your scooter"
        var enabled = true
        switch state {
        case .noScooter:
            title = "No scooter yet"
            detail = "Connect your scooter to start recording rides."
            grey = true
        case .notConnected:
            title = "Scooter not connected"
            detail = lastSeenText(lastSeenMs: i.lastSeenMs, pct: i.lastSeenPct, nowMs: Int64(i.nowS * 1000), utcOffsetMin: i.utcOffsetMin)
            grey = true
        case .connecting:
            title = "Scooter not connected"
            detail = "Connecting\u{2026} switch the scooter on."
            grey = true
            primaryTitle = "Connecting\u{2026}"
            enabled = false
        case .cantFind:
            title = "Can't find the scooter"
            detail = "Is it switched on?"
            grey = true
            primary = .tryAgain
            primaryTitle = "Try again"
        case .ready:
            title = "Scooter connected"
            detail = "Ready to ride"
            battery = i.batteryPct.map { "\($0)%" }
            primary = .startRide
            primaryTitle = "Start ride"
        case .riding:
            title = "Ride in progress"
            detail = "Recording"
            battery = i.connected ? i.batteryPct.map { "\($0)%" } : nil
            primary = .openRide
            primaryTitle = "Open live view"
        }

        return HomeModel(state: state, title: title, detail: detail, batteryText: battery, greyed: grey,
                         primary: primary, primaryTitle: primaryTitle, primaryEnabled: enabled,
                         showLocationCard: i.paired && !i.locationAlways,
                         showCrashBanner: i.lastRunCrashed,
                         lastRideText: i.lastRide.map(lastRideText))
    }

    /// Pattern L: "last seen 18:02 · 58%"; after 24 h "last seen yesterday", then "N days ago".
    /// Never seen: "never connected yet".
    public static func lastSeenText(lastSeenMs: Int64?, pct: Int?, nowMs: Int64, utcOffsetMin: Int) -> String {
        guard let seen = lastSeenMs else { return "never connected yet" }
        let age = nowMs - seen
        let tail = pct.map { " \u{00B7} \($0)%" } ?? ""
        let day: Int64 = 24 * 3_600_000
        if age < day {
            return "last seen \(clock(seen, utcOffsetMin))\(tail)"
        }
        if age < 2 * day { return "last seen yesterday\(tail)" }
        return "last seen \(age / day) days ago\(tail)"
    }

    /// "18:02" in the given UTC offset
    public static func clock(_ ms: Int64, _ utcOffsetMin: Int) -> String {
        let minutes = Int((ms / 60_000) % 1440) + utcOffsetMin
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func lastRideText(_ r: RideListItem) -> String {
        var parts = ["Last ride"]
        if let d = r.distanceM { parts.append(String(format: "%.1f km", d / 1000)) }
        if let s = r.totalS { parts.append("\(Int((s / 60).rounded())) min") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// C27 onboarding, lean: three presses, no tour. 1 Connect (scan, show the found scooter) · 2 Allow (location Always +
/// motion) · 3 Allow / Not now (notifications). Then Home.
public struct OnboardingFlow: Equatable, Sendable {
    public enum Step: Int, Sendable {
        case connect = 1, location, notifications, done
    }

    public enum Press: Equatable, Sendable {
        case connect, allow, notNow
    }

    public private(set) var step: Step = .connect
    public private(set) var presses = 0
    public private(set) var scooterFound: Bool
    /// "Set up later" left the flow without the three presses
    public private(set) var skipped = false

    public init(scooterFound: Bool = false, startAt: Step = .connect) {
        self.scooterFound = scooterFound
        self.step = startAt
    }

    public mutating func setScooterFound(_ found: Bool) { scooterFound = found }

    public var isDone: Bool { step == .done }
    public static let stepCount = 3
    public var stepText: String { step == .done ? "Done" : "\(step.rawValue) of \(Self.stepCount)" }

    /// The Connect button works once the scooter is found
    public var canConnect: Bool { step == .connect && scooterFound }

    /// Returns whether the press counted.
    @discardableResult
    public mutating func press(_ p: Press) -> Bool {
        switch (step, p) {
        case (.connect, .connect):
            guard scooterFound else { return false }
            step = .location
        case (.location, .allow), (.location, .notNow):
            step = .notifications
        case (.notifications, .allow), (.notifications, .notNow):
            step = .done
        default:
            return false
        }
        presses += 1
        return true
    }

    /// "Set up later" at step 1 (no scooter around): leaves without a press
    public mutating func skipForNow() {
        guard step != .done else { return }
        skipped = true
        step = .done
    }
}
