import Foundation

// F-27 · the charge log as a chart: a 7-day battery line drawn only between real readings (long gaps dashed, no invented curve),
// charge windows shaded, and "Each charge" rows with solid (measured) or lighter (≈) bars. Pure data; the app draws it.

public struct ChargeReading: Equatable, Sendable {
    public var ms: Int64
    public var pct: Double
    public init(ms: Int64, pct: Double) { self.ms = ms; self.pct = pct }
}

/// A piece of the line: solid between readings that are close together, dashed across a long gap.
public struct ChargeLineSegment: Equatable, Sendable {
    public var from: ChargeReading
    public var to: ChargeReading
    public var dashed: Bool
}

/// One row of "Each charge".
public struct ChargeRow: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        /// The timer ended by a real reading on connect: solid bar, plain times
        case measured
        /// The timer ended by Unplugged: lighter bar, ≈
        case estimated
        /// Found between two rides (both % real, the time in between unknown): solid bar, "seen at … at …"
        case seen
        /// Charged while away for days (time unknown)
        case away
    }

    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var startPct: Double
    public var endPct: Double
    public var source: Source

    public init(id: String, startMs: Int64, endMs: Int64, startPct: Double, endPct: Double, source: Source) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.startPct = startPct
        self.endPct = endPct
        self.source = source
    }

    public var solid: Bool { source == .measured || source == .seen }
    public var gainedPct: Double { max(0, endPct - startPct) }
}

public enum ChargeLogChart {
    /// Readings further apart than this are joined by a dashed line
    public static let gapMs: Int64 = 3 * 3_600_000
    public static let windowDays = 7

    public static func segments(_ readings: [ChargeReading]) -> [ChargeLineSegment] {
        let r = readings.sorted { $0.ms < $1.ms }
        guard r.count > 1 else { return [] }
        return (1..<r.count).map { ChargeLineSegment(from: r[$0 - 1], to: r[$0], dashed: r[$0].ms - r[$0 - 1].ms > gapMs) }
    }

    /// The readings of the last 7 days
    public static func lastWeek(_ readings: [ChargeReading], nowMs: Int64) -> [ChargeReading] {
        let from = nowMs - Int64(windowDays) * 86_400_000
        return readings.filter { $0.ms >= from && $0.ms <= nowMs }.sorted { $0.ms < $1.ms }
    }

    /// Timer entries first; a charge found between rides is dropped when a timer entry overlaps it (the timer knows more). Newest first.
    public static func rows(entries: [ChargeLogEntry], detected: [DetectedCharge]) -> [ChargeRow] {
        var out = entries.map {
            ChargeRow(id: $0.id, startMs: $0.startMs, endMs: $0.endMs, startPct: $0.startPct, endPct: $0.endPct, source: $0.measured ? .measured : .estimated)
        }
        for d in detected where !d.isSimulated {
            let overlaps = entries.contains { $0.startMs < d.windowEndAt && $0.endMs > d.windowStartAt }
            if overlaps { continue }
            out.append(ChargeRow(id: d.id, startMs: d.windowStartAt, endMs: d.windowEndAt, startPct: d.fromPct, endPct: d.toPct,
                                 source: d.inferredWhileAway ? .away : .seen))
        }
        return out.sorted { $0.startMs > $1.startMs }
    }

    /// "+32 %" and how long: "2 h 19", "overnight" (a seen gap over 8 h), "unknown" (away for days)
    public static func detail(_ row: ChargeRow) -> String {
        let gain = "+\(Int(row.gainedPct.rounded())) %"
        switch row.source {
        case .away: return "\(gain) \u{00B7} unknown"
        case .seen: return "\(gain) \u{00B7} " + (row.endMs - row.startMs > 8 * 3_600_000 ? "overnight" : "seen")
        case .measured, .estimated:
            let min = Int((Double(row.endMs - row.startMs) / 60_000).rounded())
            let d = String(format: "%d h %02d", min / 60, min % 60)
            return "\(gain) \u{00B7} " + (row.source == .estimated ? "\u{2248} " : "") + d
        }
    }
}
