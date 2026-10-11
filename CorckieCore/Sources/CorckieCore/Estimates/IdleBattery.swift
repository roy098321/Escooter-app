import Foundation

/// P6 idle battery check (T-02): the phone's battery % is logged when the app wakes or opens while no ride is active, and the drain per
/// hour is worked out from the stretches in between. Shown honestly (no margin); needs 12 h of usable stretches in the last 24 h.
public struct IdleBatterySample: Codable, Equatable {
    public enum Kind: String, Codable { case idle, rideStart, rideEnd }
    /// seconds since 1970
    public var at: Double
    public var pct: Double
    public var charging: Bool
    public var kind: Kind

    public init(at: Double, pct: Double, charging: Bool, kind: Kind = .idle) {
        self.at = at; self.pct = pct; self.charging = charging; self.kind = kind
    }
}

public enum IdleBattery {
    public static let windowS: Double = 24 * 3600
    public static let minDataS: Double = 12 * 3600
    /// a stretch longer than this between two readings is not trusted (the phone may have been used, charged or off)
    public static let maxGapS: Double = 6 * 3600
    /// two idle readings closer than this are not both kept
    public static let minSpacingS: Double = 10 * 60
    public static let keepS: Double = 48 * 3600

    public struct Report: Equatable {
        public let hoursOfData: Double
        public let readings: Int
        /// nil until `minDataS` of usable stretches
        public let pctPerHour: Double?

        public var ready: Bool { pctPerHour != nil }

        public var text: String {
            let h = String(format: "%.1f", hoursOfData)
            if let rate = pctPerHour {
                return String(format: "%.2f %% per hour idle over the last 24 h (", rate) + h + " h of data, \(readings) readings)"
            }
            return "Collecting: \(h) of 12 h of idle data so far (\(readings) readings in the last 24 h)"
        }
    }

    /// A stretch counts when it starts at an idle reading or a ride end, ends at an idle reading or a ride start, the phone was not charging
    /// at either end, the battery did not rise, and it is not longer than `maxGapS`.
    public static func report(_ samples: [IdleBatterySample], now: Double) -> Report {
        let recent = samples.filter { $0.at >= now - windowS && $0.at <= now && $0.pct >= 0 && $0.pct <= 100 }.sorted { $0.at < $1.at }
        var seconds = 0.0, drain = 0.0
        for (a, b) in zip(recent, recent.dropFirst()) {
            guard a.kind != .rideStart, b.kind != .rideEnd, !a.charging, !b.charging else { continue }
            let gap = b.at - a.at
            guard gap > 0, gap <= maxGapS, b.pct <= a.pct else { continue }
            seconds += gap
            drain += a.pct - b.pct
        }
        let hours = seconds / 3600
        let rate: Double? = seconds >= minDataS ? drain / hours : nil
        return Report(hoursOfData: hours, readings: recent.count, pctPerHour: rate)
    }

    /// Adds a reading unless an idle one is already there within `minSpacingS`; drops what is older than `keepS`.
    public static func adding(_ sample: IdleBatterySample, to samples: [IdleBatterySample]) -> [IdleBatterySample] {
        var list = samples.filter { $0.at >= sample.at - keepS }
        if sample.kind == .idle, let last = list.last, last.kind == .idle, abs(sample.at - last.at) < minSpacingS { return list }
        list.append(sample)
        return Array(list.suffix(400))
    }

    public static func fileText(_ samples: [IdleBatterySample], now: Double) -> String {
        let r = report(samples, now: now)
        var lines = ["Idle battery (P6): " + r.text,
                     "Stretches count only between idle readings / ride end -> ride start, not charging, not longer than 6 h, battery not rising.",
                     "at (UTC) · battery % · charging · kind"]
        let f = ISO8601DateFormatter()
        for s in samples.sorted(by: { $0.at < $1.at }) {
            let pct = String(format: "%.0f", s.pct)
            lines.append("\(f.string(from: Date(timeIntervalSince1970: s.at))) · \(pct) · \(s.charging ? "yes" : "no") · \(s.kind.rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
