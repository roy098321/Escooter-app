import CorckieCore
import Foundation

// M4-07: builds what the Stats tab shows from the stored rides (Core `StatsCalc`, unit tested). Compiled into AppTests.

struct StatsModel {
    var span: StatsSpan
    var mode: StatsMode
    var period: StatsPeriod
    var totals: StatsTotals
    /// km against the same point of the previous period (in %); nil for a holiday week / no base
    var comparisonPct: Double?
    var holidayTagged: Bool
    /// Recent insights (the last 10 by time)
    var recent: [Insight]
    var electricityIlsPerKwh: Double
    var fuelLPer100km: Double
    var fuelPriceIls: Double?
    var packWh: Double
    /// M4-09: the week card (Q22, Q4-weekly, Q13-weekly) of the last finished week and of this week so far
    var lastWeek: [Insight] = []
    var thisWeek: [Insight] = []
    var pastWeeks: [InsightRunner.PastWeek] = []
}

enum StatsLoader {
    private struct FuelValue: Codable { var priceIls: Double }

    static func prices(_ db: AppDatabase) -> StatsPrices {
        let q = StatsQueries(db)
        let json = (try? RideQueries(db).setting(key: "fuelPrice")) ?? nil
        let manual = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(FuelValue.self, from: $0) }?.priceIls
        return StatsPrices(packWh: CalibrationUpdater.current(db).usableWh,
                           electricityIlsPerKwh: q.number(StatsQueries.electricityKey) ?? StatsPrices.defaultElectricityIlsPerKwh,
                           fuelIlsByMonth: (try? q.fuelPricesByMonth()) ?? [:], fuelFallbackIls: manual,
                           fuelLPer100km: q.number(StatsQueries.fuelUseKey) ?? StatsPrices.defaultFuelLPer100km)
    }

    static func load(_ db: AppDatabase, span: StatsSpan, mode: StatsMode, back: Int = 0, nowMs: Int64 = FactorUpdater.nowMs(),
                     utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> StatsModel {
        let q = StatsQueries(db)
        let p = StatsCalc.period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, back: back)
        let prev = StatsCalc.period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, back: back + 1)
        let rides = (try? q.rides(from: prev.startMs, to: p.endMs)) ?? []
        let prices = prices(db)
        let tagged = span == .week && StatsCalc.holidayTagged(p, dayOffDates: (try? q.dayOffDates()) ?? [], utcOffsetMin: utcOffsetMin)
        let totals = StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: utcOffsetMin)
        let pct = back == 0 && p.isPartial
            ? StatsCalc.comparisonPct(rides, span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, holidayTagged: tagged) : nil
        var week: (last: [Insight], now: [Insight], past: [InsightRunner.PastWeek]) = ([], [], [])
        if back == 0 {
            if !db.isReadOnly { _ = try? InsightRunner.weekly(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin) }
            let start = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin)
            week = ((try? InsightQueries(db).weekCard(weekStart: start - 7 * OutsideTime.dayMs)) ?? [],
                    (try? InsightQueries(db).weekCard(weekStart: start)) ?? [],
                    InsightRunner.pastWeeks(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
        }
        return StatsModel(span: span, mode: mode, period: p, totals: totals, comparisonPct: pct, holidayTagged: tagged,
                          recent: (try? InsightQueries(db).recent()) ?? [], electricityIlsPerKwh: prices.electricityIlsPerKwh,
                          fuelLPer100km: prices.fuelLPer100km, fuelPriceIls: prices.fuelFallbackIls, packWh: prices.packWh,
                          lastWeek: week.last, thisWeek: week.now, pastWeeks: week.past)
    }

    /// Texts of the tiles, in one place (the view draws them; the ui-shot preview and the check use the same)
    static func tiles(_ m: StatsModel) -> [(label: String, value: String, note: String?)] {
        let t = m.totals
        var out: [(label: String, value: String, note: String?)] = [
            ("Rides", "\(t.rides)", t.shortHops > 0 ? "+\(t.shortHops) short \(t.shortHops == 1 ? "hop" : "hops") (\(StatsCalc.km(t.shortHopKm)))" : nil),
            ("Distance", StatsCalc.km(t.km), nil),
            ("Riding time", StatsCalc.duration(t.seconds), nil),
            ("Full charges", StatsCalc.charges(t.charges), "of the battery used"),
            ("Electricity", StatsCalc.money(t.electricityIls), String(format: "at %.2f \u{20AA}/kWh", m.electricityIlsPerKwh)),
        ]
        if let saved = t.fuelSavedIls {
            out.append(("Fuel saved", StatsCalc.money(max(0, saved)), "for the same distance, \(String(format: "%.0f", m.fuelLPer100km)) L/100 km"))
        }
        return out
    }

    static func comparisonText(_ m: StatsModel) -> String? {
        if m.holidayTagged { return "Holiday week: no comparison" }
        guard let pct = m.comparisonPct else { return nil }
        let sign = pct >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(Int(abs(pct).rounded()))% km against the same point of the previous \(m.span == .week ? "week" : "month")"
    }
}
