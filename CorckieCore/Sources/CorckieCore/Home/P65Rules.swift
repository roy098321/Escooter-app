import Foundation

// P6-5 (owner feedback on build 251): the pure rules behind the quick-fix build. UI code only draws what these return.

// MARK: B44 / B45 / B46 - what the app may say about a place as a destination

/// B44 / B45 (owner, 20 Oct): a place's time comes only from rides that really ended there. No guess from the straight line (that replaces B31).
/// Three rides give the usual Today estimate; two give the median of those two; one says how many more are needed; none says there are none.
public enum PlaceRides {
    /// rides needed for a rough estimate (the full Today estimate needs `T.t67EnoughTimeRides`)
    public static let roughMinRides = 2

    public enum Verdict: Equatable, Sendable {
        case none
        case tooFew(have: Int)
        case estimate(timeS: Double, usedPct: Double?, rides: Int)
    }

    /// - rides: every ride that ended at the place (a saved route's rides and rides whose end place is this one, each once)
    public static func verdict(rides: [RouteRideStats], nowMs: Int64, utcOffsetMin: Int) -> Verdict {
        let usable = rides.filter { !$0.excluded && ($0.totalS ?? 0) > 0 }
        if usable.isEmpty { return rides.isEmpty ? .none : .tooFew(have: 0) }
        if usable.count < roughMinRides { return .tooFew(have: usable.count) }
        if case .estimate(let e) = TodayEstimator.estimate(rides: usable, nowMs: nowMs, utcOffsetMin: utcOffsetMin,
                                                           departureMinute: DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)) {
            return .estimate(timeS: e.timeS, usedPct: e.usedPct, rides: usable.count)
        }
        guard let t = Geo.median(usable.compactMap(\.totalS)) else { return .tooFew(have: usable.count) }
        let used = usable.compactMap(\.usedPct)
        return .estimate(timeS: t, usedPct: used.count >= roughMinRides ? Geo.median(used) : nil, rides: usable.count)
    }

    /// "no rides there yet" or "1 ride there \u{00B7} estimate after 2"; nil when there is an estimate
    public static func note(_ v: Verdict) -> String? {
        switch v {
        case .none: return "no rides there yet"
        case .tooFew(let have):
            if have == 0 { return "no rides there yet" }
            return "\(have) ride\(have == 1 ? "" : "s") there \u{00B7} estimate after \(roughMinRides)"
        case .estimate: return nil
        }
    }
}

/// B46 (owner, 20 Oct): when the phone is inside a place's circle that place is "here" and cannot be the destination.
public enum PlaceHere {
    /// the circle of a place with an automatic size (the same 200 m the maps draw)
    public static let automaticRadiusM = 200.0

    public static func isHere(phone: GeoPoint?, place: GeoPoint, radiusM: Double?) -> Bool {
        guard let phone else { return false }
        return Geo.distanceM(phone, place) <= (radiusM ?? automaticRadiusM)
    }

    public static let hereWord = "You are here"

    /// the line under the quick dial when a tap lands on the place the phone is in
    public static func tapLine(name: String) -> String { "You're at \(name)" }
}

// MARK: Quick dial: the "No destination" slot, pins, and the colours

public enum QuickDialSlot {
    /// SF Symbol of the permanent first slot ("free ride")
    public static let freeRideSymbol = "infinity"
    public static let freeRideName = "No destination"
    /// the pinned places on Home at most
    public static let maxPins = 3

    /// pins as slot numbers 1, 2, 3 ... in order, no gaps
    public static func normalized(_ pins: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, id) in pins.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }).prefix(maxPins).map(\.key).enumerated() { out[id] = i + 1 }
        return out
    }

    public enum PinOutcome: Equatable, Sendable {
        case pinned([String: Int])
        /// 3 are pinned already: the owner picks which to replace
        case needsReplace(candidates: [String])
    }

    public static func pin(_ id: String, in pins: [String: Int]) -> PinOutcome {
        if pins[id] != nil { return .pinned(normalized(pins)) }
        let current = normalized(pins)
        if current.count >= maxPins { return .needsReplace(candidates: current.sorted { $0.value < $1.value }.map(\.key)) }
        var next = current
        next[id] = current.count + 1
        return .pinned(next)
    }

    public static func replace(_ old: String, with new: String, in pins: [String: Int]) -> [String: Int] {
        var next = normalized(pins)
        guard let slot = next.removeValue(forKey: old) else { return next }
        next[new] = slot
        return normalized(next)
    }

    public static func unpin(_ id: String, in pins: [String: Int]) -> [String: Int] {
        var next = pins
        next[id] = nil
        return normalized(next)
    }

    /// after a drag: the new order of the pinned ids
    public static func reordered(_ ids: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, id) in ids.prefix(maxPins).enumerated() { out[id] = i + 1 }
        return out
    }
}

public extension PlaceColours {
    /// F-29b: a dark glyph on light colours (yellow, orange, green), a white one on dark colours (blue); whichever has the better WCAG contrast
    static func glyphIsDark(hex: String) -> Bool {
        guard let c = SpeedPalette.rgb(hex) else { return true }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        let onWhite = 1.05 / (l + 0.05)
        let onBlack = (l + 0.05) / 0.05
        return onBlack >= onWhite
    }
}

// MARK: Past weeks

/// What the Past weeks chart measures (owner, 20 Oct): km, rides, time or shekels saved.
public enum PastWeeksMetric: String, CaseIterable, Sendable {
    case km, rides, time, saved

    public static let settingKey = "stats.pastWeeksMetric"

    public var switchTitle: String {
        switch self {
        case .km: return "km"
        case .rides: return "rides"
        case .time: return "time"
        case .saved: return "\u{20AA} saved"
        }
    }

    /// "Past weeks \u{00B7} km"
    public var cardTitle: String { "Past weeks \u{00B7} " + (self == .saved ? "\u{20AA} saved" : switchTitle) }

    public static func from(stored: String?) -> PastWeeksMetric { stored.flatMap { PastWeeksMetric(rawValue: $0) } ?? .km }

    public func value(_ bar: WeekBar) -> Double {
        switch self {
        case .km: return bar.km
        case .rides: return Double(bar.rides)
        case .time: return bar.seconds / 60
        case .saved: return max(0, bar.savedIls ?? 0)
        }
    }

    /// the value written on top of a bar: "61 km", "8 rides", "1 h 20", "\u{20AA}34"
    public func valueText(_ bar: WeekBar) -> String {
        switch self {
        case .km:
            return String(format: "%.0f km", bar.km)
        case .rides:
            return "\(bar.rides) ride\(bar.rides == 1 ? "" : "s")"
        case .time:
            let m = Int((bar.seconds / 60).rounded())
            return m >= 60 ? "\(m / 60) h \(m % 60)" : "\(m) min"
        case .saved:
            return "\u{20AA}\(Int(value(bar).rounded()))"
        }
    }

    /// the label under a bar: the week's first day, "6 Sep"
    public static func weekLabel(start: Int64, utcOffsetMin: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        df.dateFormat = "d MMM"
        return df.string(from: Date(timeIntervalSince1970: Double(start) / 1000))
    }
}

public extension WeekBars {
    /// The same buckets as `make(rides:...)`, with the riding time and the shekels saved per week filled in from the stats rides.
    static func make(statsRides: [StatsRide], prices: StatsPrices, nowMs: Int64, utcOffsetMin: Int, count: Int = 12) -> [WeekBar] {
        var bars = make(rides: statsRides.filter { $0.kind == "ride" }.map { (startMs: $0.startAt, km: $0.distanceM / 1000) },
                        nowMs: nowMs, utcOffsetMin: utcOffsetMin, count: count)
        let week = 7 * OutsideTime.dayMs
        for i in bars.indices {
            let start = bars[i].start
            let period = StatsPeriod(startMs: start, endMs: start + week, label: "", isPartial: false, dayCount: 7)
            let t = StatsCalc.totals(statsRides, period: period, prices: prices, utcOffsetMin: utcOffsetMin)
            bars[i].seconds = t.seconds
            bars[i].savedIls = t.fuelSavedIls
        }
        return bars
    }
}

// MARK: Hero photo framing

/// Choose photo, unedited (owner, 20 Oct): the whole photo fills the hero card (aspect fill) and can be moved and zoomed to frame it, like a
/// wallpaper. The offset is a fraction of the card, the scale is 1 (just fills) up to `maxScale`.
public struct PhotoFrame: Equatable, Codable, Sendable {
    public var scale: Double
    public var dx: Double
    public var dy: Double

    public static let maxScale = 4.0
    public static let settingKey = "scooter.photo.frame"
    public static let cutoutKey = "scooter.photo.cutout"
    /// the hero card's proportions the framing screen shows (card width / height at a normal phone)
    public static let cardAspect = 1.16

    public init(scale: Double = 1, dx: Double = 0, dy: Double = 0) {
        self.scale = scale
        self.dx = dx
        self.dy = dy
    }

    /// The frame kept so the photo always covers the whole card. `imageAspect` and `cardAspect` are width / height.
    public func clamped(imageAspect: Double, cardAspect: Double = PhotoFrame.cardAspect) -> PhotoFrame {
        let s = min(max(scale, 1), Self.maxScale)
        guard imageAspect > 0, cardAspect > 0 else { return PhotoFrame(scale: s) }
        // size of the aspect-filled photo, as a multiple of the card's width and height
        let fillW = imageAspect > cardAspect ? imageAspect / cardAspect : 1
        let fillH = imageAspect > cardAspect ? 1 : cardAspect / imageAspect
        let maxX = max(0, (fillW * s - 1) / 2)
        let maxY = max(0, (fillH * s - 1) / 2)
        return PhotoFrame(scale: s, dx: min(max(dx, -maxX), maxX), dy: min(max(dy, -maxY), maxY))
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func parse(_ text: String?) -> PhotoFrame {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(PhotoFrame.self, from: $0) } ?? PhotoFrame()
    }
}

// MARK: B50 - the scooter reports full for a few seconds after power-on

/// B50 (owner, 20 Oct): right after power-on the scooter (and its own dash) reports 100 % for a few seconds. A battery % is believed only when
/// it is stable: 3 equal readings in a row, and a reading of 100 only after `fullHoldS` seconds of readings (a really full scooter keeps
/// saying 100, a booting one drops). After `maxWaitS` without a settled value the app gives up: no % is shown or notified from the boot.
/// Once settled, every later reading is taken as it is.
public struct BootSettle: Equatable, Sendable {
    public static let needMatching = 3
    public static let fullHoldS = 8.0
    public static let maxWaitS = 15.0

    private var firstAt: Double?
    private var lastPct: Int?
    private var run = 0
    public private(set) var settledPct: Int?
    public private(set) var gaveUp = false
    private var latest: Int?

    public init() {}

    /// a new connection starts the wait again
    public mutating func reset() { self = BootSettle() }

    /// The % to show and to log: nil while waiting; the settled value; after giving up the latest reading.
    public var displayPct: Int? { settledPct ?? (gaveUp ? latest : nil) }

    /// The % the "Scooter on" notification may carry: only a settled one.
    public var notifyPct: Int? { settledPct }

    /// Feed one reading; returns the % to show (nil while waiting).
    @discardableResult
    public mutating func reading(pct: Int, at t: Double) -> Int? {
        if firstAt == nil { firstAt = t }
        latest = pct
        if settledPct != nil { settledPct = pct; return pct }
        if pct == lastPct { run += 1 } else { lastPct = pct; run = 1 }
        let held = t - (firstAt ?? t) >= Self.fullHoldS
        if run >= Self.needMatching, pct < 100 || held {
            settledPct = pct
            return pct
        }
        tick(at: t)
        return displayPct
    }

    /// Call as time passes (a packet without a battery reading counts too).
    public mutating func tick(at t: Double) {
        if settledPct == nil, let f = firstAt, t - f >= Self.maxWaitS { gaveUp = true }
    }
}
