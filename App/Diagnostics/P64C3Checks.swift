import CorckieCore
import Foundation

/// P6-4 chunk 3 checks, on made-up input and temporary databases (nothing real is read or written):
/// u90 every formula in an info sheet adds up from its shown parts (B32), u91 the Past weeks chart has one bar per week with rides (B33),
/// u92 the scooter colour is stored and read back (F-26).
@MainActor
enum P64C3Checks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    static func run() {
        runFormulas()
        runWeeks()
        runColour()
    }

    // MARK: u90

    private static func runFormulas() {
        let expect = Expect()
        let money = InfoFormula.money(grossIls: 145.7449, electricityIls: 0.2651, km: 126, lPer100: 14, rate: 0.64, charges: 0.5)
        expect(money.formula.map(\.text) == ["145.74 \u{20AA}", "0.27 \u{20AA}", "145.47 \u{20AA}"], "Money reads 145.74 \u{2212} 0.27 = 145.47")
        var seed: UInt64 = 7
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var moneyOk = true, overallOk = true, perKmOk = true
        for _ in 0..<300 {
            let gross = next() * 900, elec = next() * 40
            moneyOk = moneyOk && InfoFormula.money(grossIls: gross, electricityIls: elec, km: next() * 500, lPer100: 7, rate: 0.64, charges: 1).partsSumToTotal
            var s = OverallStats()
            s.hasFuelPrice = true
            s.fuelSavedIls = next() * 5_000
            s.electricityIls = next() * 300
            s.totalKm = next() * 3_000
            overallOk = overallOk && InfoFormula.overall(s).partsSumToTotal
            perKmOk = perKmOk && InfoFormula.perKm(s).partsSumToTotal
        }
        expect(moneyOk, "300 made-up Money sheets add up")
        expect(overallOk, "300 made-up Overall sheets add up")
        expect(perKmOk, "300 made-up Saved per km sheets divide out from the shown parts")
        let stats = StatsModel(span: .week, mode: .calendar, period: StatsCalc.period(span: .week, mode: .calendar, nowMs: 1_790_000_000_000, utcOffsetMin: 0, back: 0),
                               totals: StatsTotals(), comparisonPct: nil, holidayTagged: false, recent: [], electricityIlsPerKwh: 0.64, fuelLPer100km: 7,
                               fuelPriceIls: 8.27, packWh: 800)
        expect(StatsView.moneyInfo(stats).partsSumToTotal, "the sheet the Stats screen builds adds up")
        CheckResults.shared.set("u90", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u91

    private static func runWeeks() {
        let expect = Expect()
        let day = OutsideTime.dayMs
        let now: Int64 = 1_790_000_000_000
        let cur = InsightWeek.start(ms: now, utcOffsetMin: 0)
        let rides: [(startMs: Int64, km: Double)] = [(cur - 7 * day + day, 5), (cur - 14 * day + 2 * day, 7), (cur - 14 * day + 2 * day + 3_600_000, 1), (cur - 28 * day + 3 * day, 9)]
        let bars = WeekBars.make(rides: rides, nowMs: now, utcOffsetMin: 0)
        expect(bars.map(\.km) == [9, 0, 8, 5], "rides in 4 weeks, one riding day each: 4 bars (9, 0, 8, 5 km), not one")
        expect(bars.map(\.rides) == [1, 0, 2, 1], "the ride counts per week")
        expect(WeekBars.make(rides: [(cur + day, 50)], nowMs: now, utcOffsetMin: 0).isEmpty, "this week is not a past week")
        expect(WeekBars.make(rides: [], nowMs: now, utcOffsetMin: 0).isEmpty, "no rides, no chart")
        CheckResults.shared.set("u91", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u92

    private static func runColour() {
        let expect = Expect()
        expect(ScooterColour.allCases.map(\.title) == ["Sand", "Ember", "Cream", "Ice", "Moss", "Rose"], "six colours, Sand first")
        expect(ScooterColour.from(stored: nil) == .sand && ScooterColour.from(stored: "nonsense") == .sand, "no stored colour, or an unknown one, is Sand")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            var all = true
            for c in ScooterColour.allCases {
                SettingsValue.set(temp, ScooterColour.settingKey, c.rawValue)
                all = all && ScooterColour.from(stored: SettingsValue.text(temp, ScooterColour.settingKey)) == c
            }
            expect(all, "each of the six colours is stored and read back")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u92", expect.ok ? .pass : .fail, expect.line)
    }
}
