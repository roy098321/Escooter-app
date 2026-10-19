import CorckieCore
import Foundation

/// u66 (P6-2 chunk 3): Stats, Routes and the rest are decluttered. On made-up input: Week / Month / Year, the change chip, four Overall
/// tiles, the year bars by month, one typical number on a route row and card, small bars on the factors page.
extension P62Checks {
    @MainActor static func runStats() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        expect(StatsSpan.allCases.map(\.title) == ["Week", "Month", "Year"], "one control: Week, Month, Year")
        let now: Int64 = 1_790_000_000_000
        let year = StatsCalc.period(span: .year, mode: .calendar, nowMs: now, utcOffsetMin: 180)
        expect(year.label == "This year" && (365...366).contains(year.dayCount), "Year is the calendar year (\(year.dayCount) days)")
        let week = StatsPreview.model("stats-week")
        let trend = StatsView.trend(week)
        expect(trend == .up("12%"), "the km change is a chip on Distance, not a sentence")
        let overall = OverallLoader.tiles(StatsPreview.overall())
        expect(overall.map(\.label) == ["Total distance", "Saved", "Fuel not burnt", "CO\u{2082} avoided"], "Overall has four tiles: \(overall.map(\.label).joined(separator: ", "))")
        expect(!overall.contains { $0.value.contains("~") }, "no \"~\" on the Overall numbers")
        var yearModel = StatsPreview.model("stats-week")
        yearModel.span = .year
        yearModel.period = year
        yearModel.totals.barsKm = (0..<year.dayCount).map { _ in 1.0 }
        let bars = StatsView.barData(yearModel)
        expect(bars.values.count == 12 && abs(bars.values.reduce(0, +) - Double(year.dayCount)) < 0.001, "the year is drawn as 12 monthly bars")
        let rows = FactorsPreview.rows("factors")
        expect(rows.contains { $0.timeS != nil } && rows.contains { $0.usedPct != nil }, "factors carry the numbers for their small bars")
        let list = RoutesPreview.list("routes-list")
        let first = list.saved.first
        expect(first?.timeText != nil && first?.batteryText != nil && first?.timeText?.contains("\u{2013}") == false && first?.timeText?.contains("~") == false,
               "a route row has one typical time and battery: \(first?.timeText ?? "?") \u{00B7} \(first?.batteryText ?? "?")")
        let card = RoutesPreview.card("route-card")
        expect(card.today.timeText != nil && card.today.departure != nil, "the Today strip is a big number and chips")
        expect(card.stats.contains { $0.typical != nil } && !RouteCardView.subtitle(card).contains("Saved route") && !RouteCardView.subtitle(card).contains("based on"),
               "the route card shows typical numbers and a plain subtitle: \(RouteCardView.subtitle(card))")
        CheckResults.shared.set("u66", ok ? .pass : .fail, notes.joined(separator: " \u{00B7} "))
    }
}
