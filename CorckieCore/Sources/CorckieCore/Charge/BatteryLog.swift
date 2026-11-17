import Foundation

// N6-2 (batch 6): the Battery log chart, decluttered. One battery line from ALL readings (rest readings, timer readings and the
// smoothed level logged during rides, D-PR-09, so a ride shows as its real drain and load sag never spikes the line), a dashed
// average line of the shown range (time-weighted), and one headline "51% now · 6 charges · 12 rides". Day / Week switch.
// Never an average-day pattern: nothing here learns WHEN the rider rides. Pure; the app draws it.

public enum BatteryLog {
    public enum Range: String, CaseIterable, Sendable {
        case day, week
    }

    /// Charges closer together than this are one charge (a plug wiggle, the timer stopped and started again)
    public static let mergeChargesMs: Int64 = 15 * 60_000
    /// One point of a ride's smoothed level per this many seconds (a 5 s sample is more than a 7-day line can show)
    public static let rideStepS = 60.0

    // MARK: The line

    /// The smoothed level of one ride (the dashboard / voice level, `RideBatteryLevel`), one point a minute plus the last one.
    /// - points: the ride's stored samples (t in seconds)
    public static func smoothedRide(_ points: [SeriesPoint], whPerPct: Double, stepS: Double = rideStepS) -> [ChargeReading] {
        var level = RideBatteryLevel()
        var out: [ChargeReading] = []
        var lastEmit: Double?
        var last: (t: Double, l: Double)?
        for p in points.sorted(by: { $0.t < $1.t }) {
            level.update(t: p.t, livePct: p.batteryPct.map(Double.init), powerW: p.powerW, currentA: nil, speedKmh: p.speedKmh,
                         whPerPct: whPerPct)
            guard let l = level.level else { continue }
            last = (p.t, l)
            if lastEmit == nil || p.t - lastEmit! >= stepS {
                out.append(ChargeReading(ms: Int64(p.t * 1000), pct: clamp(l)))
                lastEmit = p.t
            }
        }
        if let last, out.last?.ms != Int64(last.t * 1000) { out.append(ChargeReading(ms: Int64(last.t * 1000), pct: clamp(last.l))) }
        return out
    }

    /// The readings inside [fromMs, toMs], sorted, plus the line's value AT the left edge when a reading before it exists (so the
    /// line starts at the edge instead of at the first reading of the range).
    public static func window(_ readings: [ChargeReading], fromMs: Int64, toMs: Int64) -> [ChargeReading] {
        let r = readings.sorted { $0.ms < $1.ms }
        var out = r.filter { $0.ms >= fromMs && $0.ms <= toMs }
        if let before = r.last(where: { $0.ms < fromMs }), let after = r.first(where: { $0.ms >= fromMs }),
           after.ms - before.ms <= ChargeLogChart.gapMs {
            let f = Double(fromMs - before.ms) / Double(after.ms - before.ms)
            out.insert(ChargeReading(ms: fromMs, pct: before.pct + (after.pct - before.pct) * f), at: 0)
        }
        return out
    }

    /// N7-7: the line's value at `ms` (between two readings less than a day apart), for the scrub callout; nil in a gap
    public static func value(at ms: Int64, in readings: [ChargeReading]) -> Double? {
        let r = readings.sorted { $0.ms < $1.ms }
        guard let after = r.firstIndex(where: { $0.ms >= ms }) else { return nil }
        if r[after].ms == ms { return r[after].pct }
        guard after > 0 else { return nil }
        let a = r[after - 1], b = r[after]
        guard b.ms - a.ms <= ChargeLogChart.gapMs else { return nil }
        return a.pct + (b.pct - a.pct) * Double(ms - a.ms) / Double(b.ms - a.ms)
    }

    // MARK: The average

    /// The time-weighted average battery level of the readings (the area under the line / its length). Pieces across a gap of
    /// more than a day (the dashed, "no reading" parts) do not count. nil = less than one solid piece.
    public static func average(_ readings: [ChargeReading]) -> Double? {
        let r = readings.sorted { $0.ms < $1.ms }
        guard r.count > 1 else { return r.first?.pct }
        var area = 0.0
        var span = 0.0
        for i in 1..<r.count {
            let dt = Double(r[i].ms - r[i - 1].ms)
            guard dt > 0, r[i].ms - r[i - 1].ms <= ChargeLogChart.gapMs else { continue }
            area += (r[i].pct + r[i - 1].pct) / 2 * dt
            span += dt
        }
        return span > 0 ? area / span : nil
    }

    /// "avg 80%"
    public static func averageText(_ avg: Double) -> String { "avg \(Int(avg.rounded()))%" }

    // MARK: Counting

    /// Charges in [fromMs, toMs]: rows that end inside the range, those starting less than 15 min after the previous one's end merged.
    public static func chargeCount(_ rows: [ChargeRow], fromMs: Int64, toMs: Int64) -> Int {
        merged(rows).filter { $0.endMs >= fromMs && $0.endMs <= toMs }.count
    }

    /// Rows merged when one starts less than `mergeChargesMs` after the previous one ended (oldest first). The merged row keeps the
    /// first one's start and the last one's end.
    public static func merged(_ rows: [ChargeRow]) -> [ChargeRow] {
        var out: [ChargeRow] = []
        for r in rows.sorted(by: { $0.startMs < $1.startMs }) {
            if var prev = out.last, r.startMs - prev.endMs < mergeChargesMs {
                prev.endMs = max(prev.endMs, r.endMs)
                prev.endPct = max(prev.endPct, r.endPct)
                out[out.count - 1] = prev
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: Words

    /// The line after the big "51%": "now · 6 charges · 12 rides" (week), "now · 1 charge · 3 rides today" (today),
    /// "· 2 charges · 4 rides on Wed" (another day; the big number is then that day's average).
    public static func headline(charges: Int, rides: Int, range: Range, dayName: String? = nil) -> String {
        let c = "\(charges) charge" + (charges == 1 ? "" : "s")
        let r = "\(rides) ride" + (rides == 1 ? "" : "s")
        switch range {
        case .week: return "now \u{00B7} \(c) \u{00B7} \(r)"
        case .day:
            if let dayName { return "avg \u{00B7} \(c) \u{00B7} \(r) on \(dayName)" }
            return "now \u{00B7} \(c) \u{00B7} \(r) today"
        }
    }

    /// The range a Day view shows: today = the last 24 h up to now; another day = its local midnight to midnight.
    /// - dayStartMs: that day's local midnight
    public static func dayRange(dayStartMs: Int64, nowMs: Int64) -> (fromMs: Int64, toMs: Int64) {
        let end = dayStartMs + 86_400_000
        if nowMs < end { return (nowMs - 86_400_000, nowMs) }
        return (dayStartMs, end)
    }

    /// The Week view: from local midnight six days ago up to now (seven day columns, today last).
    public static func weekRange(todayStartMs: Int64, nowMs: Int64) -> (fromMs: Int64, toMs: Int64) {
        (todayStartMs - 6 * 86_400_000, nowMs)
    }

    private static func clamp(_ p: Double) -> Double { min(100, max(0, p)) }
}
