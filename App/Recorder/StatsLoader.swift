import CorckieCore
import Foundation

// M4-07: builds what the Stats tab shows from the stored rides (Core `StatsCalc`, unit tested). Compiled into AppTests.

struct StatsModel {
    var span: StatsSpan
    var mode: StatsMode
    var period: StatsPeriod
    var totals: StatsTotals
    /// km change against the previous period (in %); nil for a holiday week / no base
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
    /// B33: km per finished week for the Past weeks chart (every week with rides, gaps as 0)
    var weekBars: [WeekBar] = []
    /// S12: "First week \u{00B7} from Wed 30 Sep" while the shown week is the partial first one
    var firstWeekNote: String?
    /// F-01: lifetime numbers (odometer based)
    var overall: OverallStats?
    /// the phone's offset when the model was made (the chart labels the days in local time)
    var utcOffsetMin = 0
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
                           fuelLPer100km: q.number(StatsQueries.fuelUseKey) ?? StatsPrices.defaultFuelLPer100km,
                           fuelHistory: OverallLoader.fuelHistory(db), electricityHistory: OverallLoader.electricityHistory(db))
    }

    static func load(_ db: AppDatabase, span: StatsSpan, mode: StatsMode, back: Int = 0, nowMs: Int64 = FactorUpdater.nowMs(),
                     utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> StatsModel {
        let q = StatsQueries(db)
        let p = StatsCalc.period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, back: back)
        let prev = StatsCalc.period(span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, back: back + 1)
        let rides = (try? q.rides(from: prev.startMs, to: p.endMs)) ?? []
        let prices = prices(db)
        let tagged = span == .week && mode == .calendar && StatsCalc.holidayTagged(p, dayOffDates: (try? q.dayOffDates()) ?? [], utcOffsetMin: utcOffsetMin)
        let totals = StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: utcOffsetMin)
        // F-16: a running calendar period is compared at the same point of the previous one; a rolling window with the previous window of the same length
        let pct = back == 0 && (p.isPartial || mode == .rolling)
            ? StatsCalc.comparisonPct(rides, span: span, mode: mode, nowMs: nowMs, utcOffsetMin: utcOffsetMin, holidayTagged: tagged) : nil
        var week: (last: [Insight], now: [Insight], past: [InsightRunner.PastWeek]) = ([], [], [])
        if back == 0 {
            if !db.isReadOnly { _ = try? InsightRunner.weekly(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin) }
            let start = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin)
            week = ((try? InsightQueries(db).weekCard(weekStart: start - 7 * OutsideTime.dayMs)) ?? [],
                    (try? InsightQueries(db).weekCard(weekStart: start)) ?? [],
                    InsightRunner.pastWeeks(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
        }
        var model = StatsModel(span: span, mode: mode, period: p, totals: totals, comparisonPct: pct, holidayTagged: tagged,
                          recent: (try? InsightQueries(db).recent()) ?? [], electricityIlsPerKwh: prices.electricityIlsPerKwh,
                          fuelLPer100km: prices.fuelLPer100km, fuelPriceIls: prices.fuelFallbackIls, packWh: prices.packWh,
                          lastWeek: week.last, thisWeek: week.now, pastWeeks: week.past)
        if back == 0 {
            let from = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin) - 12 * 7 * OutsideTime.dayMs
            let rows = ((try? q.rides(from: from, to: nowMs)) ?? []).filter { $0.kind == "ride" }
            model.weekBars = WeekBars.make(rides: rows.map { (startMs: $0.startAt, km: $0.distanceM / 1000) }, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        }
        model.overall = OverallLoader.load(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        model.utcOffsetMin = utcOffsetMin
        model.firstWeekNote = StatsCalc.firstWeekNote(firstRideMs: q.firstRideMs(), period: p, span: span, mode: mode, utcOffsetMin: utcOffsetMin)
        return model
    }

    /// Texts of the tiles, in one place (the view draws them; the ui-shot preview and the check use the same). No notes under them (G1).
    static func tiles(_ m: StatsModel) -> [(label: String, value: String, note: String?)] {
        let t = m.totals
        var out: [(label: String, value: String, note: String?)] = [
            ("Rides", "\(t.rides)", nil),
            ("Distance", StatsCalc.km(t.km), nil),
            ("Riding time", StatsCalc.duration(t.seconds), nil),
            ("Full charges", StatsCalc.charges(t.charges), nil),
            ("Electricity", StatsCalc.money(t.electricityIls), nil),
        ]
        if let saved = t.fuelSavedIls {
            out.append(("Fuel saved", StatsCalc.money(max(0, saved)), nil))
        }
        return out
    }
}
