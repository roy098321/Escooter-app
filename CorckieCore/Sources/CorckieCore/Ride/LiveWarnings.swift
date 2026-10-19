import Foundation

// P6-3 chunk 3 (F-19 S4 FINAL, F-22, Motor hot voice): everything the spoken ride warnings decide, pure and unit tested.
// The app only plays what comes out of `LiveVoiceDirector` (ping, haptic, voice). P-4: these are the only interruptions.

/// Numbers as words for the voice ("twenty", "six"); the synthesizer would also read digits, words keep the line steady.
public enum SpokenNumber {
    private static let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                                "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    public static func words(_ n: Int) -> String {
        if n < 0 { return String(n) }
        if n < 20 { return small[n] }
        if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : " " + small[n % 10]) }
        return String(n)
    }
}

/// "About N kilometres left": the blend of this ride and the recent rides (owner correction, 19 Oct), rounded DOWN, no safety margin (P-1).
public enum BatteryRangeSpeech {
    /// Weight on this ride = min(1, ride km / 5) x 0.7 (under ~1 km the recent rides only); the rest is the last 10 rides' %/km.
    public static func blendedPctPerKm(ridePctPerKm: Double?, rideKm: Double, recentPctPerKm: Double?) -> Double? {
        let ride = (ridePctPerKm ?? 0) > 0 ? ridePctPerKm : nil
        let recent = (recentPctPerKm ?? 0) > 0 ? recentPctPerKm : nil
        guard let r = ride else { return recent }
        guard let h = recent else { return rideKm >= 1 ? r : nil }
        let w = rideKm < 1 ? 0 : min(1, rideKm / 5) * 0.7
        return w * r + (1 - w) * h
    }

    /// Whole kilometres, rounded down; nil when no rate is known.
    public static func kmLeft(pct: Double, reservePct: Double, pctPerKm: Double?) -> Int? {
        guard let rate = pctPerKm, rate > 0 else { return nil }
        return max(0, Int(((pct - reservePct) / rate + 1e-9).rounded(.down)))
    }

    /// "Battery at twenty percent, about six kilometres left."  /  "... less than two kilometres left."
    public static func line(percent: Int, kmLeft: Int?) -> String {
        let head = "Battery at \(SpokenNumber.words(percent)) percent"
        guard let km = kmLeft else { return head + "." }
        if km < 2 { return head + ", less than two kilometres left." }
        return head + ", about \(SpokenNumber.words(km)) kilometres left."
    }
}

/// Levels 20 / 15 / 10 %: each once per ride, once the level has held ~30 s; a ride that starts below 20 % announces where it is once, at the start.
public struct BatteryWarningTracker: Equatable, Sendable {
    public static let levels = [20, 15, 10]
    public static let holdS = 30.0

    private var fired: Set<Int> = []
    private var candidate: Int?
    private var since = 0.0
    private var seenFirst = false

    public init() {}

    public mutating func reset() { self = BatteryWarningTracker() }

    /// The percent to speak ("Battery at N percent"), or nil. Call about once a second with the calibrated battery.
    public mutating func update(pct: Double?, at t: Double) -> Int? {
        guard let pct else { return nil }
        if !seenFirst {
            seenFirst = true
            if pct < Double(Self.levels[0]), let reached = Self.levels.filter({ pct <= Double($0) }).min() {
                fired.formUnion(Self.levels.filter { $0 >= reached })
                return max(0, Int(pct.rounded()))
            }
        }
        guard let reached = Self.levels.filter({ pct <= Double($0) }).min(), !fired.contains(reached) else {
            candidate = nil
            return nil
        }
        if candidate != reached {
            candidate = reached
            since = t
            return nil
        }
        guard t - since >= Self.holdS else { return nil }
        fired.formUnion(Self.levels.filter { $0 >= reached })
        candidate = nil
        return reached
    }

    /// Seconds until the level being held fires (nil when none is being held)
    public func pendingIn(at t: Double) -> Double? {
        candidate == nil ? nil : max(0, Self.holdS - (t - since))
    }

    /// The pending level fires now (merged with another warning)
    public mutating func fireNow(pct: Double) -> Int? {
        guard let c = candidate else { return nil }
        fired.formUnion(Self.levels.filter { $0 >= c })
        candidate = nil
        return c
    }
}

/// Motor hot (T47, 90 degrees C): once per ride; again only after it cooled below the level and got hot again.
public struct MotorHotTracker: Equatable, Sendable {
    private var announced = false
    public init() {}
    public mutating func reset() { announced = false }

    public mutating func update(tempC: Double?) -> Bool {
        guard let temp = tempC else { return false }
        if temp < T.t47HotC { announced = false; return false }
        if announced { return false }
        announced = true
        return true
    }
}

public enum DestinationVerdict: Equatable, Sendable {
    /// "Work: arrive with three percent."
    case arrive(pct: Int)
    /// "Work: two kilometres short."
    case short(km: Int)
}

/// What F-22 needs each second
public struct DestinationInput: Equatable, Sendable {
    public var name: String
    public var routeKm: Double
    /// Km of the route done so far
    public var alongKm: Double
    /// This ride's wheel km and the battery % when it started
    public var rideKm: Double
    public var startPct: Double
    public var pct: Double
    /// The route's usual battery % per km
    public var usualPctPerKm: Double
    public var reservePct: Double

    public init(name: String, routeKm: Double, alongKm: Double, rideKm: Double, startPct: Double, pct: Double, usualPctPerKm: Double,
                reservePct: Double = T.t80ReserveDefaultPct) {
        self.name = name
        self.routeKm = routeKm
        self.alongKm = alongKm
        self.rideKm = rideKm
        self.startPct = startPct
        self.pct = pct
        self.usualPctPerKm = usualPctPerKm
        self.reservePct = reservePct
    }

    public var thisRidePctPerKm: Double? {
        guard rideKm >= 0.3 else { return nil }
        let used = startPct - pct
        return used > 0 ? used / rideKm : nil
    }
    public var remainingKm: Double { max(0, routeKm - alongKm) }
}

public enum DestinationRules {
    public static let minKm = 3.0
    public static let minShare = 0.25
    public static let overUsualShare = 0.08
    public static let marginFactor = 1.1
    public static let holdS = 60.0

    /// Projected arrival %, honest (no margin): now - remaining km x this ride's %/km
    public static func projectedPct(_ i: DestinationInput) -> Double? {
        i.thisRidePctPerKm.map { i.pct - i.remainingKm * $0 }
    }

    /// Real doubt right now: enough ridden, 8 % above usual, and the margin-adjusted projection below the reserve.
    public static func inDoubt(_ i: DestinationInput) -> Bool {
        guard let rate = i.thisRidePctPerKm, i.routeKm > 0, i.usualPctPerKm > 0 else { return false }
        let ridden = i.alongKm >= minKm || i.alongKm >= minShare * i.routeKm
        guard ridden, i.remainingKm > 0 else { return false }
        guard rate >= i.usualPctPerKm * (1 + overUsualShare) else { return false }
        return i.pct - i.remainingKm * rate * marginFactor < i.reservePct
    }

    public static func verdict(_ i: DestinationInput) -> DestinationVerdict? {
        guard let rate = i.thisRidePctPerKm, let projected = projectedPct(i) else { return nil }
        if projected >= 0.5 { return .arrive(pct: Int(projected.rounded())) }
        let shortKm = i.remainingKm - max(0, i.pct) / rate
        return .short(km: max(1, Int(shortKm.rounded())))
    }

    public static func line(name: String, verdict: DestinationVerdict) -> String {
        switch verdict {
        case .arrive(let p): return "\(name): arrive with \(SpokenNumber.words(p)) percent."
        case .short(let km): return "\(name): \(SpokenNumber.words(km)) \(km == 1 ? "kilometre" : "kilometres") short."
        }
    }

    /// Pre-ride (silent): the Where-to row turns orange when the battery is below the route's usual need x 1.1 (+ reserve).
    public static func preRideWarning(name: String, usualNeedPct: Double?, batteryPct: Double?, reservePct: Double = T.t80ReserveDefaultPct) -> String? {
        guard let need = usualNeedPct, need > 0, let have = batteryPct else { return nil }
        guard have < need * marginFactor + reservePct else { return nil }
        return "\(name) needs about \(Int(need.rounded()))%, you have \(Int(have.rounded()))%"
    }

    /// The route's usual battery use per km: the median of its rides (excluded ones left out)
    public static func usualPctPerKm(rides: [RouteRideStats]) -> Double? {
        Geo.median(rides.filter { !$0.excluded }.compactMap { r -> Double? in
            guard let u = r.usedPct, u > 0, let d = r.distanceM, d >= 500 else { return nil }
            return u / (d / 1000)
        })
    }

    public static func usualKm(rides: [RouteRideStats]) -> Double? {
        Geo.median(rides.filter { !$0.excluded }.compactMap { r in r.distanceM.map { $0 / 1000 } })
    }
}

/// F-22 in the ride: speaks once when in real doubt for ~60 s; again only if clearly worse (arrive -> short, or 2 km further short).
public struct DestinationTracker: Equatable, Sendable {
    private var since: Double?
    private var last: DestinationVerdict?

    public init() {}
    public mutating func reset() { self = DestinationTracker() }

    public mutating func update(_ input: DestinationInput?, at t: Double) -> DestinationVerdict? {
        guard let input, DestinationRules.inDoubt(input), let v = DestinationRules.verdict(input), worse(v) else {
            since = nil
            return nil
        }
        if since == nil { since = t; return nil }
        guard t - (since ?? t) >= DestinationRules.holdS else { return nil }
        last = v
        since = nil
        return v
    }

    private func worse(_ v: DestinationVerdict) -> Bool {
        guard let l = last else { return true }
        switch (l, v) {
        case (.arrive, .short): return true
        case (.short(let a), .short(let b)): return b >= a + 2
        default: return false
        }
    }

    public func pendingIn(at t: Double) -> Double? {
        since.map { max(0, DestinationRules.holdS - (t - $0)) }
    }

    /// Fire now (merged with a battery warning): the verdict of the current input
    public mutating func fireNow(_ input: DestinationInput?) -> DestinationVerdict? {
        guard since != nil, let input, let v = DestinationRules.verdict(input) else { return nil }
        last = v
        since = nil
        return v
    }
}

/// P-4: the ONLY things that may interrupt a ride.
public enum LiveAlertKind: String, CaseIterable, Sendable {
    case battery
    case destination
    case motorHot

    /// The banners this alert may show (battery and destination speak, they show no banner)
    public var banners: Set<LiveBanner> {
        switch self {
        case .motorHot: return [.hot, .veryHot]
        case .battery, .destination: return []
        }
    }
}

public enum LiveAlert: Equatable, Sendable {
    case battery(level: Int, kmLeft: Int?)
    case destination(name: String, verdict: DestinationVerdict)
    case motorHot

    public var kind: LiveAlertKind {
        switch self {
        case .battery: return .battery
        case .destination: return .destination
        case .motorHot: return .motorHot
        }
    }

    /// The sentence the voice says
    public var line: String {
        switch self {
        case .battery(let level, let km): return BatteryRangeSpeech.line(percent: level, kmLeft: km)
        case .destination(let name, let v): return DestinationRules.line(name: name, verdict: v)
        case .motorHot: return "Motor hot."
        }
    }
}

public enum LivePing: String, Equatable, Sendable {
    case battery = "battery_ping"
    case destination = "destination_ping"
    case motor = "motor_ping"
}

/// One thing to play: the ping, the haptic pattern and the voice line (a merged one carries both alerts).
public struct LiveUtterance: Equatable, Sendable {
    public var alerts: [LiveAlert]
    public var ping: LivePing
    /// Haptic taps: two for battery and motor, three for the destination
    public var taps: Int
    public var text: String

    public init(alerts: [LiveAlert]) {
        self.alerts = alerts
        let first = alerts.first
        switch first {
        case .some(.destination): ping = .destination
        case .some(.motorHot): ping = .motor
        default: ping = .battery
        }
        taps = alerts.contains { $0.kind == .destination } ? 3 : 2
        text = alerts.map { $0.line }.joined(separator: " ")
    }
}

/// What the director needs each second of a ride
public struct LiveVoiceInput: Sendable {
    public var t: Double
    public var pct: Double?
    public var tempC: Double?
    public var rideKm: Double
    /// Last 10 rides' %/km (RealRange), nil when unknown
    public var recentPctPerKm: Double?
    public var reservePct: Double
    /// The followed route, if any
    public var route: RouteLive?

    public struct RouteLive: Sendable {
        public var name: String
        public var routeKm: Double
        public var alongKm: Double
        public var usualPctPerKm: Double

        public init(name: String, routeKm: Double, alongKm: Double, usualPctPerKm: Double) {
            self.name = name
            self.routeKm = routeKm
            self.alongKm = alongKm
            self.usualPctPerKm = usualPctPerKm
        }
    }

    public init(t: Double, pct: Double?, tempC: Double?, rideKm: Double, recentPctPerKm: Double?, reservePct: Double = T.t80ReserveDefaultPct,
                route: RouteLive? = nil) {
        self.t = t
        self.pct = pct
        self.tempC = tempC
        self.rideKm = rideKm
        self.recentPctPerKm = recentPctPerKm
        self.reservePct = reservePct
        self.route = route
    }
}

/// Runs the three trackers for one ride and merges a battery level and a destination warning that coincide (within ~20 s) into one utterance.
public struct LiveVoiceDirector: Equatable, Sendable {
    public static let mergeWithinS = 20.0

    private var battery = BatteryWarningTracker()
    private var motor = MotorHotTracker()
    private var destination = DestinationTracker()
    private var startPct: Double?

    public init() {}

    public mutating func beginRide() { self = LiveVoiceDirector() }

    public mutating func update(_ i: LiveVoiceInput) -> [LiveUtterance] {
        var out: [LiveUtterance] = []
        if motor.update(tempC: i.tempC) { out.append(LiveUtterance(alerts: [.motorHot])) }
        guard let pct = i.pct else { return out }
        if startPct == nil { startPct = pct }
        let ridePerKm: Double? = i.rideKm >= 0.3 ? max(0, (startPct ?? pct) - pct) / i.rideKm : nil
        let blended = BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: ridePerKm, rideKm: i.rideKm, recentPctPerKm: i.recentPctPerKm)
        let km = BatteryRangeSpeech.kmLeft(pct: pct, reservePct: i.reservePct, pctPerKm: blended)
        var dest: DestinationInput?
        if let r = i.route {
            dest = DestinationInput(name: r.name, routeKm: r.routeKm, alongKm: r.alongKm, rideKm: i.rideKm, startPct: startPct ?? pct, pct: pct,
                                    usualPctPerKm: r.usualPctPerKm, reservePct: i.reservePct)
        }
        let b = battery.update(pct: pct, at: i.t)
        let d = destination.update(dest, at: i.t)
        switch (b, d) {
        case (let level?, let verdict?):
            out.append(LiveUtterance(alerts: [.battery(level: level, kmLeft: km), .destination(name: dest?.name ?? "", verdict: verdict)]))
        case (let level?, nil):
            var alerts: [LiveAlert] = [.battery(level: level, kmLeft: km)]
            if let pend = destination.pendingIn(at: i.t), pend <= Self.mergeWithinS, let v = destination.fireNow(dest) {
                alerts.append(.destination(name: dest?.name ?? "", verdict: v))
            }
            out.append(LiveUtterance(alerts: alerts))
        case (nil, let verdict?):
            var alerts: [LiveAlert] = []
            if let pend = battery.pendingIn(at: i.t), pend <= Self.mergeWithinS, let level = battery.fireNow(pct: pct) {
                alerts.append(.battery(level: level, kmLeft: km))
            }
            alerts.append(.destination(name: dest?.name ?? "", verdict: verdict))
            out.append(LiveUtterance(alerts: alerts))
        case (nil, nil):
            break
        }
        return out
    }
}
