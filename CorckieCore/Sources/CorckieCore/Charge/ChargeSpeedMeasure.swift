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
