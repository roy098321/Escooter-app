import Foundation

// MARK: Note 10 - which scooter readings were ignored, and did it matter

/// Note 10 (owner 23 Oct, "Some scooter readings were ignored" never said which or whether it mattered): the readings the G1b
/// filter dropped on one ride, per kind, with the values that would have shown. The ride summary says something only when a
/// dropped value would have changed a number on the screen, in plain words; the full counts go to ⋯ → Ride info.
public struct IgnoredReadings: Codable, Equatable, Sendable {
    /// speed / battery / voltage / temperature / odometer → count
    public var byKind: [String: Int] = [:]
    public var maxSpeedKmh: Double?
    public var minBatteryPct: Int?
    public var maxBatteryPct: Int?
    public var maxTempC: Double?

    /// So many on one ride is a connection matter (note 12 diagnostics), not the rider's
    public static let connectionNoteFrom = 20

    public init(byKind: [String: Int] = [:], maxSpeedKmh: Double? = nil, minBatteryPct: Int? = nil, maxBatteryPct: Int? = nil,
                maxTempC: Double? = nil) {
        self.byKind = byKind
        self.maxSpeedKmh = maxSpeedKmh
        self.minBatteryPct = minBatteryPct
        self.maxBatteryPct = maxBatteryPct
        self.maxTempC = maxTempC
    }

    public var total: Int { byKind.values.reduce(0, +) }

    /// One dropped frame's values (from the plausibility filter)
    public mutating func add(_ dropped: [Plausibility.Field], speedKmh: Double?, batteryPct: Int?, tempC: Double?) {
        for d in dropped { byKind[d.rawValue, default: 0] += 1 }
        if dropped.contains(.speed), let v = speedKmh { maxSpeedKmh = max(maxSpeedKmh ?? v, v) }
        if dropped.contains(.battery), let b = batteryPct {
            minBatteryPct = min(minBatteryPct ?? b, b)
            maxBatteryPct = max(maxBatteryPct ?? b, b)
        }
        if dropped.contains(.temperature), let c = tempC { maxTempC = max(maxTempC ?? c, c) }
    }

    /// The plain-words lines for the ride summary: only what changed a visible number.
    public func notes(topSpeedKmh: Double?, startPct: Double?, endPct: Double?, tempPeakC: Double?) -> [String] {
        var out: [String] = []
        if let v = maxSpeedKmh, v > (topSpeedKmh ?? 0) + 0.5 {
            out.append("Top speed ignores a jump to \(Int(v.rounded())) km/h that wasn't real")
        }
        let high = max(startPct ?? -1, endPct ?? -1)
        let low = min(startPct ?? 101, endPct ?? 101)
        if let b = maxBatteryPct, startPct != nil || endPct != nil, Double(b) > high + 0.5 {
            out.append("Battery ignores a reading of \(b) % that wasn't real")
        } else if let b = minBatteryPct, startPct != nil || endPct != nil, Double(b) < low - 0.5 {
            out.append("Battery ignores a reading of \(b) % that wasn't real")
        }
        if let c = maxTempC, c > (tempPeakC ?? -.infinity) + 0.5 {
            out.append("Temperature ignores a reading of \(Int(c.rounded())) \u{00B0}C that wasn't real")
        }
        if (byKind[Plausibility.Field.odometer.rawValue] ?? 0) > 0 {
            out.append("Distance ignores an odometer jump that wasn't real")
        }
        return out
    }

    /// ⋯ → Ride info: "Ignored readings: speed 3 · battery 1"; nil when none
    public var infoLine: String? {
        guard total > 0 else { return nil }
        let order = Plausibility.Field.allCases.map(\.rawValue)
        let parts = order.compactMap { k in byKind[k].map { "\(k) \($0)" } }
        return "Ignored readings: " + parts.joined(separator: " \u{00B7} ")
    }
}
