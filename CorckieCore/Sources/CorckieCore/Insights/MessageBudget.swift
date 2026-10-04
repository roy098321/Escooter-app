import Foundation

/// M1-07: the live banner part of the message budget (CONCEPT "Message budget", C24; CALC_SPEC 9.4, T98).
/// Pure logic: the live view (M1-12) asks `tick` once a second and shows what comes back.
///
/// Rules: one banner at a time, in C24 priority order; at ride start at most 2 messages (the rest go to the
/// ride summary); a timed banner shows at most 8 s; the waiting queue holds at most 2 (older ones drop to
/// the summary); a banner can be tapped only below 5 km/h; very hot, disconnected and No GPS stay while the
/// condition lasts; hot is announced once per ride.

public enum LiveBanner: Int, CaseIterable, Comparable, Sendable {
    case veryHot = 1, choicePoint, disconnected, noGps, batteryTight, hot, sameRide, starting, notRiding, destination, headwind

    /// C24 order: 1 = most important. Disconnected and No GPS share row 3.
    public var priority: Int {
        switch self {
        case .veryHot: return 1
        case .choicePoint: return 2
        case .disconnected, .noGps: return 3
        case .batteryTight: return 4
        case .hot: return 5
        case .sameRide, .starting, .notRiding: return 6
        case .destination: return 7
        case .headwind: return 8
        }
    }

    public static func < (a: LiveBanner, b: LiveBanner) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.rawValue < b.rawValue
    }

    /// Stays while its condition lasts (no 8 s limit, no queue)
    public var isSticky: Bool {
        switch self {
        case .veryHot, .disconnected, .noGps: return true
        default: return false
        }
    }

    /// Announced once per ride (a choice point can come again)
    var oncePerRide: Bool { !isSticky && self != .choicePoint }

    public var text: String {
        switch self {
        case .veryHot: return "Motor very hot"
        case .choicePoint: return "Choice point ahead"
        case .disconnected: return "Scooter disconnected · reconnecting…"
        case .noGps: return "No GPS"
        case .batteryTight: return "Battery is tight for this ride"
        case .hot: return "Motor hot"
        case .sameRide: return "Same ride?"
        case .starting: return "Starting…"
        case .notRiding: return "Not riding"
        case .destination: return "Destination guess"
        case .headwind: return "Headwind today"
        }
    }
}

public struct BannerQueue: Sendable {
    public struct Shown: Equatable, Sendable {
        public var banner: LiveBanner
        public var since: Double
        /// Tappable only below 5 km/h (T98)
        public var tappable: Bool
    }

    public static let maxAtRideStart = 2
    public static let maxWaiting = 2

    public let bannerS: Double
    public let tappableBelowKmh: Double

    private var sticky: [LiveBanner: Double] = [:]      // banner -> since
    private var current: (banner: LiveBanner, since: Double)?
    private var waiting: [LiveBanner] = []              // arrival order
    private var raisedThisRide: Set<LiveBanner> = []
    private var heat = HeatWatch()
    /// Messages that never got on screen; the ride summary shows them
    public private(set) var droppedToSummary: [LiveBanner] = []

    public init(bannerS: Double = T.t98BannerS, tappableBelowKmh: Double = T.t98TappableBelowKmh) {
        self.bannerS = bannerS
        self.tappableBelowKmh = tappableBelowKmh
    }

    /// A new ride: forget the old one. At most 2 of the start messages are shown, the rest go to the summary.
    public mutating func beginRide(messages: [LiveBanner]) {
        sticky = [:]
        current = nil
        waiting = []
        raisedThisRide = []
        heat = HeatWatch()
        droppedToSummary = []
        let timed = Array(Set(messages.filter { !$0.isSticky })).sorted()
        for (i, b) in timed.enumerated() {
            if i < Self.maxAtRideStart {
                raisedThisRide.insert(b)
                waiting.append(b)
            } else {
                droppedToSummary.append(b)
            }
        }
    }

    /// A timed message (or a sticky one, which then stays until `setActive(_, false)`).
    public mutating func raise(_ banner: LiveBanner, at t: Double) {
        if banner.isSticky {
            setActive(banner, true, at: t)
            return
        }
        if banner.oncePerRide {
            if raisedThisRide.contains(banner) { return }
            raisedThisRide.insert(banner)
        }
        if current?.banner == banner || waiting.contains(banner) { return }
        enqueue(banner)
    }

    public mutating func setActive(_ banner: LiveBanner, _ on: Bool, at t: Double) {
        guard banner.isSticky else { return }
        if on {
            if sticky[banner] == nil { sticky[banner] = t }
        } else {
            sticky[banner] = nil
        }
    }

    /// M38 through `HeatWatch`: very hot stays until the motor is below hot; hot is announced once.
    public mutating func feedHeat(tempC: Double, at t: Double) {
        let announced = heat.update(tempC)
        setActive(.veryHot, heat.level == .veryHot, at: t)
        if announced == .hot { raise(.hot, at: t) }
    }

    private mutating func enqueue(_ banner: LiveBanner) {
        waiting.append(banner)
        while waiting.count > Self.maxWaiting {
            // drop the least important; among equals, the oldest
            var worst = 0
            for i in 1..<waiting.count where waiting[i].priority > waiting[worst].priority {
                worst = i
            }
            droppedToSummary.append(waiting.remove(at: worst))
        }
    }

    /// Call about once a second with the speed shown on screen. Returns the banner to show, if any.
    public mutating func tick(at t: Double, speedKmh: Double) -> Shown? {
        if let c = current, t - c.since >= bannerS { current = nil }

        var best: (banner: LiveBanner, isSticky: Bool)?
        for b in sticky.keys where best == nil || b < best!.banner { best = (b, true) }
        if let c = current, best == nil || c.banner < best!.banner { best = (c.banner, false) }
        for b in waiting where best == nil || b < best!.banner { best = (b, false) }

        guard let pick = best else { return nil }
        let tappable = speedKmh < tappableBelowKmh
        if pick.isSticky {
            if let c = current {                 // a more important message pushes the timed one back
                current = nil
                enqueue(c.banner)
            }
            return Shown(banner: pick.banner, since: sticky[pick.banner] ?? t, tappable: tappable)
        }
        if let c = current, c.banner == pick.banner {
            return Shown(banner: c.banner, since: c.since, tappable: tappable)
        }
        if let i = waiting.firstIndex(of: pick.banner) { waiting.remove(at: i) }
        if let c = current { enqueue(c.banner) }
        current = (pick.banner, t)
        return Shown(banner: pick.banner, since: t, tappable: tappable)
    }

    /// The rider taps the banner away. Refused (false) at 5 km/h or more.
    @discardableResult
    public mutating func dismissCurrent(speedKmh: Double) -> Bool {
        guard speedKmh < tappableBelowKmh, current != nil else { return false }
        current = nil
        return true
    }

    /// How many timed messages are waiting (at most 2)
    public var waitingCount: Int { waiting.count }
}
