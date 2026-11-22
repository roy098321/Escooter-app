import Foundation

/// I2 "Measure charging speed": the rider types the scooter screen's battery % every ~20 minutes while it charges (the scooter is off
/// while charging, so the app cannot read it). Two or more entries give the charging speed in % per hour, which then replaces the
/// learned value. A rider feature, by choice; the rider can stop at any time.
public enum ChargeSpeedMeasure {
    public struct Entry: Equatable, Sendable {
        public let atMs: Int64
        public let pct: Double
        public init(atMs: Int64, pct: Double) { self.atMs = atMs; self.pct = pct }
    }

    /// Entries must span at least this long, or the rounding of a whole-number % dominates
    public static let minSpanMs: Int64 = 20 * 60_000
    /// Plausible speeds, % per hour
    public static let plausible = 1.0...40.0
    /// The reminder interval while measuring
    public static let reminderEverySeconds: TimeInterval = 20 * 60

    /// Speed in % per hour from the first and the last entry; nil when there is not enough, or it is not a charge
    public static func rate(_ entries: [Entry]) -> Double? {
        let sorted = entries.sorted { $0.atMs < $1.atMs }
        guard let first = sorted.first, let last = sorted.last, last.atMs - first.atMs >= minSpanMs else { return nil }
        let hours = Double(last.atMs - first.atMs) / 3_600_000
        let rate = (last.pct - first.pct) / hours
        guard plausible.contains(rate) else { return nil }
        return (rate * 10).rounded() / 10
    }

    /// "1700000000000:62,1700001200000:68" <-> entries (stored as one setting value)
    public static func encode(_ entries: [Entry]) -> String {
        entries.map { "\($0.atMs):\(Int($0.pct.rounded()))" }.joined(separator: ",")
    }

    public static func decode(_ text: String?) -> [Entry] {
        (text ?? "").split(separator: ",").compactMap { part in
            let bits = part.split(separator: ":")
            guard bits.count == 2, let at = Int64(bits[0]), let pct = Double(bits[1]) else { return nil }
            return Entry(atMs: at, pct: pct)
        }
    }

    /// A typed value must be a real battery %
    public static func validPct(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), (0...100).contains(v) else { return nil }
        return v
    }
}

/// EXPERIMENTAL (hotfix 110.221126.01, owner 22 Nov): measure the charging speed without typing. While charging, the rider switches
/// the scooter on for ~15 s every 20 minutes; each switch-on gives one reading (the scooter's % and voltage, after the first 10 s
/// so the fake 100 % at switch-on is skipped). Once 3+ readings over 40+ minutes line up, the speed is known: no full charge needed.
/// Read-only: nothing is sent to the scooter.
public enum ChargeAutoMeasure {
    public struct Reading: Equatable, Codable, Sendable {
        public let atMs: Int64
        public let pct: Double
        public let voltage: Double?
        public init(atMs: Int64, pct: Double, voltage: Double?) { self.atMs = atMs; self.pct = pct; self.voltage = voltage }
    }

    public enum Result: Equatable, Sendable {
        /// Need more readings (how many more at least)
        case needMore(Int)
        /// Readings don't line up (the biggest miss in %): one more is asked for
        case notSteady(maxMissPct: Double)
        /// Done: % per hour
        case done(pctPerHour: Double)
    }

    public static let minReadings = 3
    public static let minSpanMs: Int64 = 40 * 60_000
    /// Whole-number % from the scooter: a miss of up to 2 % from the straight line still counts as steady
    public static let maxMissPct = 2.0
    /// Skip the first seconds after switch-on (the fake 100 %)
    public static let skipS = 10.0

    /// One reading from the first seconds after a switch-on: the median % and voltage after the first 10 s, standing still
    public static func reading(_ frames: [ScooterFrame], atMs: Int64) -> Reading? {
        guard let t0 = frames.first?.t else { return nil }
        let ok = frames.filter { $0.t - t0 >= skipS && ($0.speedKmh ?? 0) == 0 }
        let pcts = ok.compactMap(\.batteryPct).map(Double.init).sorted()
        guard !pcts.isEmpty else { return nil }
        let volts = ok.compactMap(\.voltage).sorted()
        return Reading(atMs: atMs, pct: pcts[pcts.count / 2], voltage: volts.isEmpty ? nil : volts[volts.count / 2])
    }

    /// Straight-line fit of % against time; done when 3+ readings over 40+ min line up within 2 %
    public static func result(_ readings: [Reading]) -> Result {
        let r = readings.sorted { $0.atMs < $1.atMs }
        guard r.count >= minReadings, let first = r.first, let last = r.last, last.atMs - first.atMs >= minSpanMs else {
            return .needMore(max(1, minReadings - r.count))
        }
        let xs = r.map { Double($0.atMs - first.atMs) / 3_600_000 }, ys = r.map(\.pct)
        let n = Double(r.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in r.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
        guard sxx > 0 else { return .needMore(1) }
        let slope = sxy / sxx, icept = my - slope * mx
        let miss = r.indices.map { abs(ys[$0] - (icept + slope * xs[$0])) }.max() ?? 0
        guard miss <= maxMissPct else { return .notSteady(maxMissPct: (miss * 10).rounded() / 10) }
        guard ChargeSpeedMeasure.plausible.contains(slope) else { return .notSteady(maxMissPct: 0) }
        return .done(pctPerHour: (slope * 10).rounded() / 10)
    }
}
