import Foundation

// MARK: B56 - the scooter's battery % flips ±1 between neighbours (100/99/100…)

/// B56b: per-scooter auto-detect. Over the last `window` value changes of the RAW battery %, the share that is a flip
/// (A → B → A with |A − B| = 1). The filter is on above `onShare` (once `minChanges` changes are known), off below it:
/// a scooter that doesn't flip is used as it is. Codable, so the app keeps it per scooter between connections.
public struct BatteryFlipDetector: Codable, Equatable, Sendable {
    /// Rolling window of value changes (BUGS B56b: "last ~200 changes")
    public static let window = 200
    /// Before this many changes nothing is decided (the filter stays off)
    public static let minChanges = 20
    /// On above ~10 % flips (B56b)
    public static let onShare = 0.10

    /// One flag per value change, newest last: true = that change undid the one before (a flip)
    public private(set) var flips: [Bool] = []
    /// The two raw values before the newest one (for the A → B → A test)
    private var previous: Int?
    private var last: Int?

    public init() {}

    /// Feed one raw reading (repeats of the same value are not changes).
    public mutating func reading(_ pct: Int) {
        guard pct != last else { return }
        if let l = last {
            let flip = previous == pct && abs(pct - l) == 1
            flips.append(flip)
            if flips.count > Self.window { flips.removeFirst(flips.count - Self.window) }
        }
        previous = last
        last = pct
    }

    /// A new connection: the A → B → A chain starts again, the history stays.
    public mutating func newConnection() {
        previous = nil
        last = nil
    }

    public var changes: Int { flips.count }
    public var flipShare: Double { flips.isEmpty ? 0 : Double(flips.filter { $0 }.count) / Double(flips.count) }
    /// The filter is used for this scooter
    public var filterOn: Bool { changes >= Self.minChanges && flipShare > Self.onShare }

    /// For diagnostics: "flips 78 % of 200 changes · filter on"
    public var line: String {
        "flips \(Int((flipShare * 100).rounded())) % of \(changes) changes \u{00B7} filter \(filterOn ? "on" : "off")"
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func parse(_ text: String?) -> BatteryFlipDetector {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(BatteryFlipDetector.self, from: $0) } ?? BatteryFlipDetector()
    }
}

/// B56 (BUGS): hysteresis on the battery %. Shows the lower of a ±1 pair; goes down at once when a lower value appears;
/// goes up only on +2 (or more), or on +1 held for `upHoldS` (charging). Used for everything that reads the scooter's
/// %: the frame the pipeline hands on is the filtered one (Home / Scooter, ride start / end and %/km, the 20/15/10
/// warnings, F-22, the boot settle B50, the charge log, insights); the raw value stays in the raw packets and `rawPct`.
/// With the detector off (a scooter that doesn't flip) the raw value passes unchanged.
public struct BatteryFilter: Codable, Equatable, Sendable {
    /// A +1 must last this long before it is believed (B56: "a sustained +1 ≥ 60 s, i.e. charging")
    public static let upHoldS = 60.0

    public var detector = BatteryFlipDetector()
    /// The value handed on (nil before the first reading of this connection)
    public private(set) var shown: Int?
    /// The newest raw reading (diagnostics)
    public private(set) var rawPct: Int?
    /// Since when every reading has been above `shown` (a pending rise)
    private var upSince: Double?
    /// The lowest reading during the pending rise (the rise is to this value)
    private var upLow: Int?

    public init(detector: BatteryFlipDetector = BatteryFlipDetector()) {
        self.detector = detector
    }

    /// A new connection (the boot readings come again): the shown value starts fresh, the detector keeps its history.
    public mutating func newConnection() {
        shown = nil
        rawPct = nil
        upSince = nil
        upLow = nil
        detector.newConnection()
    }

    /// Feed one raw reading at time `t` (seconds); returns the value to use.
    public mutating func reading(_ pct: Int, at t: Double) -> Int {
        rawPct = pct
        detector.reading(pct)
        let filtered = hysteresis(pct, at: t)
        return detector.filterOn ? filtered : pct
    }

    /// The hysteresis always runs (so switching the filter on mid-connection starts from a sensible value).
    private mutating func hysteresis(_ pct: Int, at t: Double) -> Int {
        guard let s = shown else {
            shown = pct
            return pct
        }
        if pct <= s {
            shown = pct            // down at once (or the same value): any pending rise is off
            upSince = nil
            upLow = nil
            return pct
        }
        if pct >= s + 2 {
            shown = pct            // a real jump up (charged, or a reconnect after charging)
            upSince = nil
            upLow = nil
            return pct
        }
        // +1: believed only when it is held
        if upSince == nil { upSince = t }
        upLow = min(upLow ?? pct, pct)
        if let since = upSince, t - since >= Self.upHoldS, let low = upLow {
            shown = low
            upSince = nil
            upLow = nil
        }
        return shown ?? pct
    }
}
