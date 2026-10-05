import Foundation

/// M4-07: the Stats tab numbers (CALC_SPEC section 8): M34 week / month (calendar and rolling, holiday week tag, partial period
/// compared with the same point of the previous one), M35 full charges used and electricity cost, M35b fuel money saved.
/// Pure logic. A ride belongs to the period it started in; short hops are counted separately (not in rides / time); merge groups
/// do not exist yet (a merged ride would count once).

public struct StatsRide: Equatable, Sendable {
    public var startAt: Int64
    public var utcOffsetMin: Int
    /// ride / shortHop
    public var kind: String
    public var distanceM: Double
    public var totalS: Double
    public var usedPct: Double?

    public init(startAt: Int64, utcOffsetMin: Int, kind: String, distanceM: Double, totalS: Double, usedPct: Double?) {
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.kind = kind
        self.distanceM = distanceM
        self.totalS = totalS
        self.usedPct = usedPct
    }
}

public enum StatsSpan: String, CaseIterable, Sendable {
    case week, month

    public var title: String { self == .week ? "Week" : "Month" }
}

public enum StatsMode: String, CaseIterable, Sendable {
    case calendar, rolling

    public var title: String { self == .calendar ? "Calendar" : "Rolling" }
}

public struct StatsPeriod: Equatable, Sendable {
    public var startMs: Int64
    /// exclusive
    public var endMs: Int64
    public var label: String
    /// The current period is still running
    public var isPartial: Bool
    public var dayCount: Int
}

/// What the numbers need besides the rides
public struct StatsPrices: Equatable, Sendable {
    /// Usable battery in Wh (calibrated or the prior); 100% of it = one full charge
    public var packWh: Double
    /// ILS per kWh (setting, default 0.64)
    public var electricityIlsPerKwh: Double
    /// ILS per litre by month ("yyyy-MM"), and the price used when the month is missing (last known or the manual one)
    public var fuelIlsByMonth: [String: Double]
    public var fuelFallbackIls: Double?
    /// L per 100 km of the car / petrol scooter the km replace (setting)
    public var fuelLPer100km: Double

    public static let defaultElectricityIlsPerKwh = 0.64
    public static let defaultFuelLPer100km = 7.0

    public init(packWh: Double, electricityIlsPerKwh: Double = StatsPrices.defaultElectricityIlsPerKwh, fuelIlsByMonth: [String: Double] = [:],
                fuelFallbackIls: Double? = nil, fuelLPer100km: Double = StatsPrices.defaultFuelLPer100km) {
        self.packWh = packWh
        self.electricityIlsPerKwh = electricityIlsPerKwh
        self.fuelIlsByMonth = fuelIlsByMonth
        self.fuelFallbackIls = fuelFallbackIls
        self.fuelLPer100km = fuelLPer100km
    }
}

public struct StatsTotals: Equatable, Sendable {
    public var rides = 0
    public var shortHops = 0
    public var km = 0.0
    public var shortHopKm = 0.0
    public var seconds = 0.0
    /// M35: sum of used % of rides and short hops / 100, shown "~", 1 decimal
    public var charges = 0.0
    public var electricityIls = 0.0
    /// M35b: nil without a fuel price
    public var fuelSavedIls: Double?
    /// km per local day of the period (week: 7 bars, month: its days, rolling: 7 / 30)
    public var barsKm: [Double] = []
    public var isEmpty: Bool { rides == 0 && shortHops == 0 }
}

public enum StatsCalc {
    private static let day = OutsideTime.dayMs

    private static func calendar(_ offsetMin: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: offsetMin * 60) ?? TimeZone(identifier: "UTC")!
        return c
    }


    /// The period `back` steps before the current one (0 = current). Calendar: week Sunday to Saturday, month = calendar month.
    /// Rolling: the last 7 / 30 days ending now (each step back is a full 7 / 30 days earlier).
    public static func period(span: StatsSpan, mode: StatsMode, nowMs: Int64, utcOffsetMin: Int, back: Int = 0) -> StatsPeriod {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
        func short(_ ms: Int64) -> String { df.dateFormat = "d MMM"; return df.string(from: date(ms)) }
        switch (span, mode) {
        case (.week, .calendar):
            let start = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin) - Int64(back) * 7 * day
            let end = start + 7 * day
            let label = back == 0 ? "This week" : back == 1 ? "Last week" : "\(short(start)) – \(short(end - 1))"
            return StatsPeriod(startMs: start, endMs: end, label: label, isPartial: back == 0, dayCount: 7)
        case (.month, .calendar):
            let cal = calendar(utcOffsetMin)
            let comps = cal.dateComponents([.year, .month], from: date(nowMs))
            let first = cal.date(from: comps)!
            let start = cal.date(byAdding: .month, value: -back, to: first)!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            df.dateFormat = "MMMM yyyy"
            let startMs = Int64(start.timeIntervalSince1970 * 1000), endMs = Int64(end.timeIntervalSince1970 * 1000)
            let n = Int(((endMs - startMs) / day))
            return StatsPeriod(startMs: startMs, endMs: endMs, label: back == 0 ? "This month" : df.string(from: start), isPartial: back == 0, dayCount: n)
        case (.week, .rolling), (.month, .rolling):
            let n = span == .week ? 7 : 30
            let end = nowMs - Int64(back) * Int64(n) * day
            let start = end - Int64(n) * day
            let label = back == 0 ? "Last \(n) days" : "\(short(start)) – \(short(end))"
            return StatsPeriod(startMs: start, endMs: end, label: label, isPartial: false, dayCount: n)
        }
    }

    /// Rides that started inside the period
    public static func rides(_ all: [StatsRide], in p: StatsPeriod) -> [StatsRide] {
        all.filter { $0.startAt >= p.startMs && $0.startAt < p.endMs }
    }

    public static func totals(_ all: [StatsRide], period p: StatsPeriod, prices: StatsPrices, utcOffsetMin: Int) -> StatsTotals {
        var t = StatsTotals()
        var bars = [Double](repeating: 0, count: max(1, p.dayCount))
        var fuel = 0.0
        var anyFuel = false
        let kwhPerPct = prices.packWh / 100 / 1000
        for r in rides(all, in: p) {
            let km = r.distanceM / 1000
            let index = Int((r.startAt - p.startMs) / day)
            if r.kind == "shortHop" {
                t.shortHops += 1
                t.shortHopKm += km
            } else {
                t.rides += 1
                t.km += km
                t.seconds += r.totalS
                if bars.indices.contains(index) { bars[index] += km }
            }
            let used = r.usedPct ?? 0
            t.charges += used / 100
            // M35b: rides over 2 km, the same distance by car minus what the ride cost in electricity
            if r.kind == "ride", km > 2, let price = fuelPrice(forStart: r.startAt, offsetMin: r.utcOffsetMin, prices: prices) {
                fuel += km * prices.fuelLPer100km / 100 * price - used * kwhPerPct * prices.electricityIlsPerKwh
                anyFuel = true
            }
        }
        t.electricityIls = t.charges * prices.packWh / 1000 * prices.electricityIlsPerKwh
        t.fuelSavedIls = anyFuel ? fuel : (prices.fuelFallbackIls != nil || !prices.fuelIlsByMonth.isEmpty ? 0 : nil)
        t.barsKm = bars
        return t
    }

    /// The fuel price of the month the ride was in, else the last known / manual one
    static func fuelPrice(forStart ms: Int64, offsetMin: Int, prices: StatsPrices) -> Double? {
        let local = ms + Int64(offsetMin) * 60_000
        let key = String(OutsideTime.day(local).prefix(7))
        return prices.fuelIlsByMonth[key] ?? prices.fuelFallbackIls
    }

    /// Holiday week / month tag: the period contains a day-off holiday ("yyyy-MM-dd" local dates)
    public static func holidayTagged(_ p: StatsPeriod, dayOffDates: Set<String>, utcOffsetMin: Int) -> Bool {
        var t = p.startMs
        while t < p.endMs {
            if dayOffDates.contains(String(OutsideTime.day(t + Int64(utcOffsetMin) * 60_000).prefix(10))) { return true }
            t += day
        }
        return false
    }

    /// Partial current period against the same point of the previous one (km, in %); nil without a base or for a holiday week
    public static func comparisonPct(_ all: [StatsRide], span: StatsSpan, mode: StatsMode, nowMs: Int64, utcOffsetMin: Int, holidayTagged: Bool) -> Double? {
        guard !holidayTagged else { return nil }
        let cur = period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        let prev = period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, back: 1)
        // the same point: as far into the previous period as we are into this one
        let elapsed = min(nowMs, cur.endMs) - cur.startMs
        let prevCut = StatsPeriod(startMs: prev.startMs, endMs: min(prev.endMs, prev.startMs + elapsed), label: "", isPartial: false, dayCount: prev.dayCount)
        let a = rides(all, in: cur).filter { $0.kind == "ride" }.reduce(0.0) { $0 + $1.distanceM } / 1000
        let b = rides(all, in: prevCut).filter { $0.kind == "ride" }.reduce(0.0) { $0 + $1.distanceM } / 1000
        guard b >= 1 else { return nil }
        return (a - b) / b * 100
    }

    // MARK: Text

    public static func money(_ ils: Double) -> String { String(format: "%.2f \u{20AA}", ils) }
    public static func km(_ v: Double) -> String { String(format: v >= 100 ? "%.0f km" : "%.1f km", v) }

    public static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    /// "~1.4 charges"
    public static func charges(_ v: Double) -> String { String(format: "~%.1f", v) }
}
