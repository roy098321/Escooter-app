import Charts
import CorckieCore
import SwiftUI

/// M4-07 / P6-2: the Stats tab. One Week / Month / Year control, then clear sections: the period (distance with a change chip, rides,
/// time, per-day bars), Money (one net number), Overall (4 tiles), and below them What affects my rides, Past weeks and the recent
/// insights. Explanations sit behind an ⓘ (G1). Numbers are made in CorckieCore (`StatsCalc`, unit tested); this view draws them.
/// No records, goals or streaks (P-3).
struct StatsView: View {
    var preview: StatsModel?

    @AppStorage("stats.span") private var spanRaw = StatsSpan.week.rawValue
    @State private var back = 0
    @State private var model: StatsModel?

    private var span: StatsSpan { StatsSpan(rawValue: spanRaw) ?? .week }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let m = preview ?? model {
                    content(m)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .background { MapBackdrop().ignoresSafeArea() }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)   // G3: small title; G12: prices live in Settings only
            .onAppear(perform: load)
            .onChange(of: spanRaw) { _, _ in back = 0; load() }
            .onChange(of: back) { _, _ in load() }
            .screen("Stats")
        }
    }

    private func content(_ m: StatsModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            spanControl(m)
            periodHeader(m)
            if m.totals.isEmpty {
                emptyCard
            } else {
                periodTiles(m)
                bars(m)
                moneySection(m)
            }
            if let overall = m.overall { OverallSection(stats: overall) }
            if preview == nil { factorsLink }
            pastWeeksLink(m)
            recentSection(m)
        }
        .padding(16)
    }

    private func spanControl(_ m: StatsModel) -> some View {
        Group {
            if preview == nil {
                GlassSegmented(options: StatsSpan.allCases.map { ($0.rawValue, $0.title) }, selection: $spanRaw)
                    .accessibilityLabel("Span")
            } else {
                GlassSegmented(options: StatsSpan.allCases.map { ($0.rawValue, $0.title) }, selection: .constant(m.span.rawValue))
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar").font(.largeTitle).foregroundStyle(.secondary)
            Text("No rides yet").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard(radius: DS.Radius.hero, padding: 0)
    }

    /// The section label of the period ("THIS WEEK") with the earlier / later arrows on the right
    private func periodHeader(_ m: StatsModel) -> some View {
        HStack(spacing: 0) {
            SectionHeader(m.period.label) {
                if m.holidayTagged { Image(systemName: "party.popper").font(.caption).foregroundStyle(Theme.canyon).accessibilityLabel("Holiday week") }
                if let note = m.firstWeekNote { InfoButton("First week", text: note) }
            }
            Spacer(minLength: 0)
            Button { back += 1 } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Earlier")
                .disabled(preview != nil)
            Button { back = max(0, back - 1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Later")
                .disabled(back == 0 || preview != nil)
        }
        .foregroundStyle(Theme.canyon)
    }

    /// ST3 / ST4: Distance (with the change chip), Rides, Time; labels only
    private func periodTiles(_ m: StatsModel) -> some View {
        let t = m.totals
        return StatTileGrid {
            StatTile(value: StatsCalc.km(t.km), label: "Distance", trend: Self.trend(m))
            StatTile(value: "\(t.rides)", label: "Rides")
            StatTile(value: StatsCalc.duration(t.seconds), label: "Time")
        }
    }

    /// ST6: Money is ONE number, the net saved; the way it is made sits behind the ⓘ
    @ViewBuilder private func moneySection(_ m: StatsModel) -> some View {
        if let saved = m.totals.fuelSavedIls {
            SectionHeader("Money") { InfoButton("Money", text: Self.moneyInfo(m)) }
            HStack {
                Text(StatsCalc.money(max(0, saved)))
                    .scaledFont(28, weight: .semibold, mono: true, relativeTo: .title)
                    .foregroundStyle(Theme.accentInk)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("saved").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
            .accessibilityElement(children: .combine)
        }
    }

    /// ST3: the km change as a small chip value ("12%"); nil without a base or in a holiday week
    static func trend(_ m: StatsModel) -> StatTile.Trend? {
        guard !m.holidayTagged, let pct = m.comparisonPct else { return nil }
        let text = "\(Int(abs(pct).rounded()))%"
        return pct >= 0 ? .up(text) : .down(text)
    }

    static func moneyInfo(_ m: StatsModel) -> String {
        let t = m.totals
        let net = max(0, t.fuelSavedIls ?? 0)
        let gross = StatsCalc.money(net + t.electricityIls)
        let l100 = String(format: "%.0f", m.fuelLPer100km)
        let rate = String(format: "%.2f", m.electricityIlsPerKwh)
        let first = "Saved is the fuel money you did not spend, \(gross) for the same distance by car at \(l100) L per 100 km, "
        let second = "minus the electricity of your rides, \(StatsCalc.money(t.electricityIls)) at \(rate) \u{20AA} per kWh."
        return first + second + " You used \(StatsCalc.charges(t.charges)) full charges."
    }

    private func bars(_ m: StatsModel) -> some View {
        let data = Self.barData(m)
        return Chart(Array(data.values.enumerated()), id: \.offset) { item in
            BarMark(x: .value("Day", item.offset + 1), y: .value("km", item.element))
                .foregroundStyle(Theme.accent)
                .cornerRadius(4)
        }
        .chartXScale(domain: 0.4...(Double(max(data.values.count, 1)) + 0.6))      // all bars inside the plot, the last one too
        .chartXAxis { barAxis(data.labels) }
        .chartYAxis(.hidden)
        .frame(height: 130)
        .padding(.horizontal, DS.Space.cardPad)
        .padding(.vertical, 12)
        .glassCard(padding: 0)
        .padding(.top, DS.Space.row)
        .accessibilityLabel("Distance per day, bar chart")
    }

    private func barAxis(_ labels: [String]) -> some AxisContent {
        AxisMarks(values: Array(stride(from: 1, through: labels.count, by: labels.count > 12 ? 5 : 1))) { value in
            AxisValueLabel {
                if let i = value.as(Int.self), i >= 1, i <= labels.count { Text(labels[i - 1]).font(.caption2) }
            }
        }
    }

    /// The bars: a week and a month by day, a year by month; with the axis letters ("S M T W T F S", "1 6 11 ...", "J F M ...")
    static func barData(_ m: StatsModel) -> (values: [Double], labels: [String]) {
        switch m.span {
        case .week:
            return (m.totals.barsKm, ["S", "M", "T", "W", "T", "F", "S"])
        case .month:
            return (m.totals.barsKm, m.totals.barsKm.indices.map { String($0 + 1) })
        case .year:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            var months = [Double](repeating: 0, count: 12)
            for (i, km) in m.totals.barsKm.enumerated() {
                let date = Date(timeIntervalSince1970: Double(m.period.startMs) / 1000 + (Double(i) + 0.5) * 86_400)
                let month = cal.component(.month, from: date) - 1
                if months.indices.contains(month) { months[month] += km }
            }
            return (months, ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"])
        }
    }

    private var factorsLink: some View {
        NavigationLink { FactorsView() } label: {
            HStack {
                Label("What affects my rides", systemImage: "wind")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
        .padding(.top, DS.Space.block)
    }

    /// ST10: the finished weeks as a small bar chart; a tap opens the compact table
    @ViewBuilder private func pastWeeksLink(_ m: StatsModel) -> some View {
        if !m.pastWeeks.isEmpty {
            NavigationLink { PastWeeksView(weeks: m.pastWeeks) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Past weeks", systemImage: "calendar")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    PastWeeksChart(weeks: m.pastWeeks, height: 60)
                }
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.row)
        }
    }

    /// ST8: the recent insights sit at the bottom, and are not drawn when there are none
    @ViewBuilder private func recentSection(_ m: StatsModel) -> some View {
        if !m.recent.isEmpty {
            SectionHeader("Recent insights")
            VStack(spacing: DS.Space.row) {
                ForEach(Array(m.recent.enumerated()), id: \.offset) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb").foregroundStyle(Theme.canyon).frame(width: 24)
                        Text(item.element.text).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(DS.Space.cardPad)
                    .glassCard(padding: 0)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func load() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        model = StatsLoader.load(db, span: span, mode: .calendar, back: back)
    }
}

/// Settings for the cost numbers: electricity price and the car's consumption (the fuel price itself is in Settings → Costs).
struct CostSettingsView: View {
    @State private var electricity = ""
    @State private var fuelUse = ""

    var body: some View {
        Form {
            Section {
                TextField("0.64", text: $electricity).keyboardType(.decimalPad)
            } header: {
                HStack(spacing: 4) {
                    Text("Electricity price (\u{20AA} per kWh)").textCase(nil)
                    InfoButton("Electricity price", text: "Full charges used times the battery size times this price. Default 0.64.")
                }
            }
            .glassRows()
            Section {
                TextField("7", text: $fuelUse).keyboardType(.decimalPad)
            } header: {
                HStack(spacing: 4) {
                    Text("Car fuel use (L per 100 km)").textCase(nil)
                    InfoButton("Car fuel use", text: "Saved is the same distance by car at this use and the fuel price, minus the electricity of the ride. Default 7.")
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Prices")
        .onAppear {
            guard let db = AppModel.shared.displayDatabase else { return }
            let q = StatsQueries(db)
            electricity = String(q.number(StatsQueries.electricityKey) ?? StatsPrices.defaultElectricityIlsPerKwh)
            fuelUse = String(q.number(StatsQueries.fuelUseKey) ?? StatsPrices.defaultFuelLPer100km)
        }
        .onChange(of: electricity) { _, v in save(StatsQueries.electricityKey, v, range: 0.01...10) }
        .onChange(of: fuelUse) { _, v in save(StatsQueries.fuelUseKey, v, range: 1...30) }
        .screen("Prices")
    }

    private func save(_ key: String, _ text: String, range: ClosedRange<Double>) {
        guard let db = AppModel.shared.database, !db.isReadOnly,
              let v = Double(text.replacingOccurrences(of: ",", with: ".")), range.contains(v) else { return }
        if key == StatsQueries.electricityKey {
            // F-01: the new rate applies from today on; the rate that applied until now is kept for the past
            let old = StatsQueries(db).number(key) ?? StatsPrices.defaultElectricityIlsPerKwh
            let today = OverallLoader.localDay(FactorUpdater.nowMs(), offsetMin: RouteCardLoader.currentOffsetMin())
            try? PriceHistoryQueries(db).setElectricity(v, from: today, currentDefault: old)
        }
        try? StatsQueries(db).setNumber(key, v)
    }
}

/// F-01 / ST5: the Overall section of Stats, from the scooter's lifetime odometer. Four headline tiles; the rest behind the ⓘ.
struct OverallSection: View {
    let stats: OverallStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Overall") { InfoButton("Overall", text: OverallLoader.details(stats)) }
            StatTileGrid {
                ForEach(Array(OverallLoader.tiles(stats).enumerated()), id: \.offset) { _, t in StatTile(value: t.value, label: t.label) }
            }
            if stats.usesUnverifiedPrice {
                Label("Check the fuel price", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Theme.accentInk)
                    .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Made-up numbers for the CI ui-shots (`-uiShot stats-week`, `stats-month`, `stats-empty`).
enum StatsPreview {
    static func overall() -> OverallStats {
        let fuel = PriceHistory([PricePoint(validFrom: "2026-09-01", value: 8.25), PricePoint(validFrom: "2026-10-01", value: 8.27)])
        let elec = PriceHistory([PricePoint(validFrom: "2000-01-01", value: 0.64)])
        let rides = [OverallRide(day: "2026-10-05", km: 19, usedPct: 48), OverallRide(day: "2026-10-08", km: 11, usedPct: 22)]
        return OverallCalc.compute(OverallInput(purchaseDay: "2026-09-02", latestOdometerKm: 722.1, odometerAtFirstRideKm: 692.1, rides: rides,
                                                whPerPct: 8.1, fuel: fuel, electricity: elec, todayDay: "2026-10-13"))
    }

    static func model(_ name: String) -> StatsModel {
        let month = name == "stats-month"
        let empty = name == "stats-empty"
        let firstWeek = name == "stats-first-week"
        let now: Int64 = 1_790_000_000_000
        let period = StatsCalc.period(span: month ? .month : .week, mode: .calendar, nowMs: now, utcOffsetMin: 180)
        var t = StatsTotals()
        if !empty {
            t.rides = month ? 31 : 9
            t.shortHops = month ? 6 : 2
            t.km = month ? 214.6 : 58.3
            t.shortHopKm = month ? 5.1 : 1.4
            t.seconds = month ? 41_400 : 11_300
            t.charges = month ? 6.8 : 1.9
            t.electricityIls = t.charges * 0.8 * 0.64
            t.fuelSavedIls = t.km * 0.07 * 8.27 - t.electricityIls
            var bars: [Double] = []
            for i in 0..<period.dayCount {
                let weekend: Bool = i % 7 == 5 || i % 7 == 6
                let km: Double = weekend ? 0 : 6 + Double((i * 5) % 9)
                bars.append(km)
            }
            t.barsKm = bars
        } else {
            t.barsKm = [Double](repeating: 0, count: period.dayCount)
        }
        let week = name == "week-card" ? [Insight(type: .q22Weekly, weekStart: now, text: "Last week: 58 km, 9 rides, 3 h 8 min, +6 km more than the week before. Wind cost you about 4 min over the week.", basedOnN: 9, createdAt: now)] : []
        let insights = empty ? [] : [
            Insight(type: .q15After, rideId: "p1", routeId: "A", text: "Tailwind saved you ~1.5 min and ~1% battery today.", basedOnN: 9, createdAt: now),
            Insight(type: .q4After, rideId: "p2", routeId: "A", text: "1:10 min slower than usual: headwind (~1:00 min).", basedOnN: 8, createdAt: now - 86_400_000),
        ]
        var model = StatsModel(span: month ? .month : .week, mode: .calendar, period: period, totals: t, comparisonPct: empty || firstWeek ? nil : 12,
                               holidayTagged: false, recent: insights, electricityIlsPerKwh: 0.64, fuelLPer100km: 7, fuelPriceIls: 8.27, packWh: 800,
                               lastWeek: week, pastWeeks: empty ? [] : WeekPreview.weeks())
        model.overall = empty ? nil : overall()
        if firstWeek { model.firstWeekNote = "First week \u{00B7} from Wed 7 Oct" }
        return model
    }
}

// MARK: Past weeks

/// ST10: km per finished week as a small bar chart (oldest on the left)
struct PastWeeksChart: View {
    let weeks: [InsightRunner.PastWeek]
    var height: CGFloat = 120

    var body: some View {
        let ordered = Array(weeks.sorted { $0.start < $1.start }.enumerated())
        Chart(ordered, id: \.offset) { item in
            BarMark(x: .value("Week", item.offset), y: .value("km", item.element.km))
                .foregroundStyle(Theme.accent)
                .cornerRadius(3)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityLabel("Distance per past week, bar chart")
    }
}

/// The finished weeks before the last one, newest first, as a compact table (made live from the rides; weeks under 2 riding days
/// have no summary).
struct PastWeeksView: View {
    var weeks: [InsightRunner.PastWeek]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.row) {
                if weeks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No weeks yet").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .glassCard(radius: DS.Radius.hero, padding: 0)
                } else {
                    PastWeeksChart(weeks: weeks)
                        .padding(DS.Space.cardPad)
                        .glassCard(padding: 0)
                    table
                }
            }
            .padding(DS.Space.gutter)
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Past weeks")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Past weeks")
    }

    private var table: some View {
        VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.element.id) { i, w in
                if i > 0 { Divider() }
                HStack {
                    Text(w.title.replacingOccurrences(of: "Week of ", with: ""))
                    Spacer()
                    Text("\(StatsCalc.km(w.km)) \u{00B7} \(w.rides) rides").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.subheadline)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, DS.Space.cardPad)
        .glassCard(padding: 0)
    }
}

enum WeekPreview {
    static func weeks() -> [InsightRunner.PastWeek] {
        [InsightRunner.PastWeek(start: 1, title: "Week of 20 Sep", lines: [], km: 61, rides: 8),
         InsightRunner.PastWeek(start: 2, title: "Week of 13 Sep", lines: [], km: 40, rides: 6),
         InsightRunner.PastWeek(start: 3, title: "Week of 6 Sep", lines: [], km: 22, rides: 3)]
    }
}
