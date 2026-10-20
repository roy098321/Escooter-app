import Foundation

/// F-25 / B32: the content of an info sheet, and the rounding rule for every formula it shows: the parts are rounded first and the total
/// is computed from the SHOWN parts (145.74 - 0.27 = 145.47, never 145.46).
public enum InfoRole: String, Sendable { case start, plus, minus, divide, result }

public struct InfoFormulaRow: Equatable, Sendable {
    public var label: String
    /// the value exactly as shown (already rounded to `decimals`)
    public var value: Double
    public var decimals: Int
    public var unit: String
    public var role: InfoRole

    public init(_ label: String, _ value: Double, decimals: Int = 2, unit: String = "", role: InfoRole) {
        self.label = label
        self.value = value
        self.decimals = decimals
        self.unit = unit
        self.role = role
    }

    public var text: String { String(format: "%.\(decimals)f", value) + (unit.isEmpty ? "" : " " + unit) }
}

/// Where a "Based on" value is set (the app maps it to a screen)
public enum InfoLink: String, Sendable { case costSettings, priceHistory }

public struct InfoBasedOn: Equatable, Sendable {
    public var label: String
    public var value: String
    public var link: InfoLink?
    public init(_ label: String, _ value: String, link: InfoLink? = nil) {
        self.label = label
        self.value = value
        self.link = link
    }
}

public struct InfoContent: Equatable, Sendable {
    public var lead: String
    public var formula: [InfoFormulaRow] = []
    public var basedOn: [InfoBasedOn] = []
    /// at most one plain sentence
    public var caveat: String?

    public init(lead: String, formula: [InfoFormulaRow] = [], basedOn: [InfoBasedOn] = [], caveat: String? = nil) {
        self.lead = lead
        self.formula = formula
        self.basedOn = basedOn
        self.caveat = caveat
    }

    /// B32: does the result row equal what the shown parts give (start +/- parts, or start / divisor), at the result's own rounding?
    public var partsSumToTotal: Bool { InfoFormula.consistent(formula) }
}

public enum InfoFormula {
    /// round to `decimals`, halves away from zero
    public static func round(_ v: Double, _ decimals: Int = 2) -> Double {
        let f = pow(10.0, Double(decimals))
        return (v * f).rounded(.toNearestOrAwayFromZero) / f
    }

    /// the shown net: shown gross minus shown electricity
    public static func shownSaved(gross: Double, electricity: Double) -> Double {
        round(round(gross) - round(electricity))
    }

    /// the shown "per km": the shown saved money divided by the shown distance
    public static func shownPerKm(saved: Double, km: Double, kmDecimals: Int) -> Double {
        let k = round(km, kmDecimals)
        return k > 0 ? round(round(saved) / k) : 0
    }

    public static func kmDecimals(_ km: Double) -> Int { km >= 100 ? 0 : 1 }

    public static func consistent(_ rows: [InfoFormulaRow]) -> Bool {
        guard rows.count >= 3, let first = rows.first, first.role == .start, let last = rows.last, last.role == .result else { return rows.isEmpty }
        var acc = first.value
        for r in rows.dropFirst().dropLast() {
            switch r.role {
            case .plus: acc += r.value
            case .minus: acc -= r.value
            case .divide: acc = r.value > 0 ? acc / r.value : 0
            default: return false
            }
        }
        return round(acc, last.decimals) == round(last.value, last.decimals)
    }

    // MARK: the sheets that show a formula

    /// Money (Stats): fuel money for the distance, minus the electricity
    public static func money(grossIls: Double, electricityIls: Double, km: Double, lPer100: Double, rate: Double, charges: Double) -> InfoContent {
        let g = round(grossIls), e = round(electricityIls)
        let d = kmDecimals(km)
        let kmText = String(format: "%.\(d)f", round(km, d))
        return InfoContent(
            lead: "Fuel money you didn't spend, minus charging.",
            formula: [InfoFormulaRow("Car fuel for \(kmText) km", g, unit: "\u{20AA}", role: .start),
                      InfoFormulaRow("Electricity", e, unit: "\u{20AA}", role: .minus),
                      InfoFormulaRow("Saved", round(g - e), unit: "\u{20AA}", role: .result)],
            basedOn: [InfoBasedOn("Car", String(format: "%.0f L / 100 km", lPer100), link: .costSettings),
                      InfoBasedOn("Electricity", String(format: "%.2f \u{20AA} / kWh", rate), link: .costSettings),
                      InfoBasedOn("Fuel price", "by month", link: .priceHistory),
                      InfoBasedOn("Charging", "~" + String(format: "%.1f", charges) + " full charges")])
    }

    /// Overall (Stats): the lifetime numbers
    public static func overall(_ s: OverallStats) -> InfoContent {
        var formula: [InfoFormulaRow] = []
        if s.hasFuelPrice {
            let f = round(s.fuelSavedIls), e = round(s.electricityIls)
            formula = [InfoFormulaRow("Fuel money saved", f, unit: "\u{20AA}", role: .start),
                       InfoFormulaRow("Electricity spent", e, unit: "\u{20AA}", role: .minus),
                       InfoFormulaRow("Saved", round(f - e), unit: "\u{20AA}", role: .result)]
        }
        var based = [InfoBasedOn("Total distance", OverallCalc.km(s.totalKm) + " (odometer)"),
                     InfoBasedOn("With CorckieApp", OverallCalc.km(s.kmWithApp) + " (logged rides)"),
                     InfoBasedOn("Before the app", OverallCalc.km(s.kmBefore) + " (estimate)", link: .priceHistory),
                     InfoBasedOn("Full charges used", String(format: "%.1f", s.fullCharges)),
                     InfoBasedOn("Fuel not burnt", OverallCalc.litres(s.carLitres))]
        if s.usesUnverifiedPrice { based.append(InfoBasedOn("Fuel price", "unverified, please check it", link: .priceHistory)) }
        return InfoContent(
            lead: "Your scooter's lifetime numbers, from its odometer.",
            formula: formula, basedOn: based,
            caveat: "Money is counted month by month at the price valid then, and CO\u{2082} avoided is an estimate (petrol minus grid electricity).")
    }

    /// the shown lifetime per-km value (the tile uses the same number as the sheet)
    public static func shownPerKm(_ s: OverallStats) -> Double? {
        guard OverallCalc.savedPerKm(s) != nil else { return nil }
        return shownPerKm(saved: max(0, shownSaved(gross: s.fuelSavedIls, electricity: s.electricityIls)), km: s.totalKm, kmDecimals: kmDecimals(s.totalKm))
    }

    /// Saved per km (Stats): lifetime saved divided by lifetime km
    public static func perKm(_ s: OverallStats) -> InfoContent {
        let saved = max(0, shownSaved(gross: s.fuelSavedIls, electricity: s.electricityIls))
        let d = kmDecimals(s.totalKm)
        let km = round(s.totalKm, d)
        return InfoContent(
            lead: "What every kilometre by scooter instead of car saves you.",
            formula: [InfoFormulaRow("Saved, lifetime", saved, unit: "\u{20AA}", role: .start),
                      InfoFormulaRow("Distance", km, decimals: d, unit: "km", role: .divide),
                      InfoFormulaRow("Saved per km", shownPerKm(saved: saved, km: s.totalKm, kmDecimals: d), unit: "\u{20AA}", role: .result)],
            basedOn: [InfoBasedOn("Car", String(format: "%.0f L / 100 km", s.carLPer100km), link: .costSettings),
                      InfoBasedOn("Fuel price", "each month's", link: .priceHistory)])
    }
}

/// F-26: the scooter colours of the hero card (hex RGB); the title is what the menu shows, the raw value is what is stored.
public enum ScooterColour: String, CaseIterable, Sendable {
    case sand, ember, cream, ice, moss, rose

    public static let settingKey = "scooter.colour"

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var hex: Int {
        switch self {
        case .sand: return 0xD9C4A0
        case .ember: return 0xF89355
        case .cream: return 0xF6E6CC
        case .ice: return 0xB9D3E6
        case .moss: return 0x9DBB8A
        case .rose: return 0xE7A1A8
        }
    }

    /// the stored value; anything unknown or missing is Sand
    public static func from(stored: String?) -> ScooterColour { stored.flatMap(ScooterColour.init(rawValue:)) ?? .sand }
}

/// B33: km per week for the small "Past weeks" chart. One bucket per finished week (the last one included, back `count` weeks), oldest
/// first, from the first week that has a ride; weeks without rides are 0 so the gaps show. A week is never dropped for having few riding days.
public struct WeekBar: Equatable, Sendable {
    public var start: Int64
    public var km: Double
    public var rides: Int

    public init(start: Int64, km: Double, rides: Int) {
        self.start = start
        self.km = km
        self.rides = rides
    }
}

public enum WeekBars {
    public static func make(rides: [(startMs: Int64, km: Double)], nowMs: Int64, utcOffsetMin: Int, count: Int = 12) -> [WeekBar] {
        let week = 7 * OutsideTime.dayMs
        let current = InsightWeek.start(ms: nowMs, utcOffsetMin: utcOffsetMin)
        var bars: [WeekBar] = []
        for i in stride(from: count, through: 1, by: -1) {
            let start = current - Int64(i) * week
            let inWeek = rides.filter { $0.startMs >= start && $0.startMs < start + week }
            bars.append(WeekBar(start: start, km: inWeek.reduce(0) { $0 + max(0, $1.km) }, rides: inWeek.count))
        }
        while let f = bars.first, f.rides == 0 { bars.removeFirst() }
        return bars
    }
}
