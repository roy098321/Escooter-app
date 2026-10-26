import Charts
import CorckieCore
import SwiftUI

/// M4-07 / P6-2 / P6-3: the Stats tab. One Week / Month / Year control (and, F-16, a small Calendar / Rolling switch right of the title), then clear sections: the period (distance with a change chip, rides,
/// time, per-day bars), Money (one net number), Overall (4 tiles), and below them What affects my rides, Past weeks and the F-21
/// Insights (at most 3 cards). Explanations sit behind an ⓘ (G1). Numbers are made in CorckieCore (`StatsCalc`, unit tested); this view draws them.
/// No records, goals or streaks (P-3).
struct StatsView: View {
    var preview: StatsModel?

    @AppStorage("stats.span") private var spanRaw = StatsSpan.week.rawValue
    /// A7: the bars grow from the baseline on first show and when the span changes, each 30 ms after the one before (nil = all grown)
    @State private var grownBars: Set<Int>?
    @State private var replayToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// F-16: Calendar (this week / month / year) or Rolling (the last 7 / 30 / 365 days), remembered
    @AppStorage("stats.mode") private var modeRaw = StatsMode.calendar.rawValue
    /// P6-5: what the Past weeks chart measures, remembered (Core `PastWeeksMetric`)
    @AppStorage(PastWeeksMetric.settingKey) private var metricRaw = PastWeeksMetric.km.rawValue
    @State private var back = 0
    @State private var model: StatsModel?
    /// Note 8: the tapped bar (its readout shows above the chart)
    @State private var selectedBar: Int?

    private var span: StatsSpan { StatsSpan(rawValue: spanRaw) ?? .week }
    private var mode: StatsMode { StatsMode(rawValue: modeRaw) ?? .calendar }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let m = preview ?? model {
                    content(m)
                } else {
                    // A8: the final layout as grey shapes, then it cross-fades into the real numbers (no spinner)
                    content(StatsPreview.model("stats-week")).redacted(reason: .placeholder)
                        .allowsHitTesting(false).accessibilityHidden(true).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model == nil)
            .background { MapBackdrop().ignoresSafeArea() }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)   // G3: small title; G12: prices live in Settings only
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { modeSwitch }
            }
            .onAppear(perform: load)
            .onChange(of: spanRaw) { _, _ in back = 0; selectedBar = nil; load(); Haptics.tick(); replayBars(model.map { Self.barData($0).values.count } ?? 0) }
            .onChange(of: metricRaw) { _, _ in selectedBar = nil }
            .onChange(of: modeRaw) { _, _ in back = 0; load() }
            .onChange(of: back) { _, _ in selectedBar = nil; load() }
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
            InsightsSection(board: m.insights)   // F-21
        }
        .padding(16)
    }

    /// F-16: the compact Calendar / Rolling switch in the top bar, right of the "Stats" title
    private var modeSwitch: some View {
        let current = preview?.mode ?? mode
        return HStack(spacing: 0) {
            modeButton("Calendar", .calendar, current)
            modeButton("Rolling", .rolling, current)
        }
        .padding(2)
        .background(Theme.chip, in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar or rolling periods")
    }

    private func modeButton(_ title: String, _ value: StatsMode, _ current: StatsMode) -> some View {
        let on = current == value
        return Button {
            if preview == nil { modeRaw = value.rawValue }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(on ? Theme.accent : Color.clear, in: Capsule())
                .foregroundStyle(on ? Theme.onAccent : Color.primary)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
                if let note = m.firstWeekNote { InfoButton("First week", info: InfoContent(lead: note)) }
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
        return StatTileGrid(weighted: true) {   // Distance 2 : Rides 1 : Time 2
            StatTile(value: StatsCalc.km(t.km), label: "Distance", trend: Self.trend(m)).tileWeight(2)
            StatTile(value: "\(t.rides)", label: "Rides").tileWeight(1)
            StatTile(value: StatsCalc.duration(t.seconds), label: "Time").tileWeight(2)
        }
    }

    /// ST6: Money is ONE number, the net saved; the way it is made sits behind the ⓘ
    @ViewBuilder private func moneySection(_ m: StatsModel) -> some View {
        if m.totals.fuelSavedIls != nil {
            SectionHeader("Money") { InfoButton("Money", info: Self.moneyInfo(m)) }
            HStack {
                Text(StatsCalc.money(max(0, Self.shownSaved(m))))
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

    static func moneyInfo(_ m: StatsModel) -> InfoContent {
        let t = m.totals
        let net = max(0, t.fuelSavedIls ?? 0)
        return InfoFormula.money(grossIls: net + t.electricityIls, electricityIls: t.electricityIls, km: t.km, lPer100: m.fuelLPer100km,
                                 rate: m.electricityIlsPerKwh, charges: t.charges)
    }

    /// B32: the headline is the shown fuel money minus the shown electricity, the same number the sheet adds up to
    static func shownSaved(_ m: StatsModel) -> Double {
        let t = m.totals
        let net = max(0, t.fuelSavedIls ?? 0)
        return InfoFormula.shownSaved(gross: net + t.electricityIls, electricity: t.electricityIls)
    }

    /// Note 8: ONE chart: a clear title ("km per day"), the km · rides · time · \u{20AA} saved switch, dashed reference lines with their
    /// values behind the bars, a tap on a bar reads it ("13 Oct · 18 km"). Built in Core (`StatsChart`).
    private func bars(_ m: StatsModel) -> some View {
        let metric = PastWeeksMetric.from(stored: metricRaw)
        let chart = StatsChart.make(m.totals, metric: metric, period: m.period, span: m.span, mode: m.mode, utcOffsetMin: m.utcOffsetMin)
        let values = chart.bars.map(\.value)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(chart.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let i = selectedBar, let text = chart.readout(i) {
                    Text(text).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accentInk)
                }
            }
            PastWeeksSwitch()
            Chart {
                ForEach(chart.references, id: \.self) { r in
                    RuleMark(y: .value("Reference", r))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: 1) {
                            Text(StatsChart.valueText(r, metric)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                ForEach(Array(values.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("Day", item.offset + 1), y: .value(chart.title, item.element * (grownBars?.contains(item.offset) ?? true ? 1 : 0)))
                        .foregroundStyle(selectedBar == nil || selectedBar == item.offset ? Theme.accent : Theme.accent.opacity(0.35))
                        .cornerRadius(4)
                }
            }
            .chartYScale(domain: 0...chart.scaleTop)   // hotfix 01 (H4): bars and dashed lines share one value scale
            .onAppear { replayBars(values.count) }
            .chartXScale(domain: 0.4...(Double(max(values.count, 1)) + (values.count > 12 ? 1.3 : 0.6)))      // all bars inside the plot, and room for the last label ("31") at the right edge
            .chartXAxis { barAxis(chart.bars.map(\.axisLabel)) }
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard let plot = proxy.plotFrame else { return }
                            let x = tap.location.x - geo[plot].origin.x
                            guard let v: Double = proxy.value(atX: x) else { return }
                            let i = Int(v.rounded()) - 1
                            guard values.indices.contains(i) else { selectedBar = nil; return }
                            selectedBar = selectedBar == i ? nil : i
                            Haptics.tick()
                        })
                }
            }
            .frame(height: 150)
        }
        .padding(.horizontal, DS.Space.cardPad)
        .padding(.vertical, 12)
        .glassCard(padding: 0)
        .padding(.top, DS.Space.row)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(chart.title), bar chart")
    }

    private func replayBars(_ count: Int) {
        guard !reduceMotion, count > 0 else { return }   // Reduce Motion: no growth, no stagger
        grownBars = []
        replayToken += 1
        let token = replayToken
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i) + 0.02) {
                guard token == replayToken else { return }
                withAnimation(.easeOut(duration: 0.4)) { grownBars?.insert(i) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(count) + 0.5) { if token == replayToken { grownBars = nil } }
    }

    private func barAxis(_ labels: [String]) -> some AxisContent {
        AxisMarks(values: Array(stride(from: 1, through: labels.count, by: labels.count > 12 ? 5 : 1))) { value in
            AxisValueLabel {
                if let i = value.as(Int.self), i >= 1, i <= labels.count { Text(labels[i - 1]).font(.caption2) }
            }
        }
    }

    /// The bars with their axis letters (made in Core: `StatsCalc.chartBars`): calendar week "S M T W T F S", month "1 6 11 ...", year "J F M ...";
    /// rolling windows are labelled with the days they really cover.
    static func barData(_ m: StatsModel) -> (values: [Double], labels: [String]) {
        StatsCalc.chartBars(barsKm: m.totals.barsKm, period: m.period, span: m.span, mode: m.mode, utcOffsetMin: m.utcOffsetMin)
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

    /// Note 8: the Past weeks card left Stats (the one chart above has its switch); its long history stays one tap away
    @ViewBuilder private func pastWeeksLink(_ m: StatsModel) -> some View {
        if !m.weekBars.isEmpty {
            NavigationLink { PastWeeksView(weeks: m.pastWeeks, bars: m.weekBars, utcOffsetMin: m.utcOffsetMin) } label: {
                HStack {
                    Label("Past weeks", systemImage: "calendar")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.row)
        }
    }

    private func load() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        model = StatsLoader.load(db, span: span, mode: mode, back: back)
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
                    InfoButton("Electricity price", info: InfoContent(lead: "What your charging costs per kWh.", basedOn: [InfoBasedOn("Cost", "full charges used \u{00D7} battery size \u{00D7} this price"), InfoBasedOn("Default", "0.64 \u{20AA} / kWh")]))
                }
            }
            .glassRows()
            Section {
                TextField("7", text: $fuelUse).keyboardType(.decimalPad)
            } header: {
                HStack(spacing: 4) {
                    Text("Car fuel use (L per 100 km)").textCase(nil)
                    InfoButton("Car fuel use", info: InfoContent(lead: "Saved is the same distance by car at this use and the fuel price, minus the electricity of the ride.", basedOn: [InfoBasedOn("Default", "7 L / 100 km")]))
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
        .hidesTabBar()
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

/// F-01 / ST5 / F-20: the Overall section of Stats, from the scooter's lifetime odometer. Four headline tiles, and one wide highlight tile
/// ("0.77 ₪ / km saved") in the two free slots next to CO₂; the rest sits behind the ⓘ.
struct OverallSection: View {
    let stats: OverallStats
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Overall") { InfoButton("Overall", info: InfoFormula.overall(stats)) }
            tiles
            if stats.usesUnverifiedPrice {
                Label("Check the fuel price", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Theme.accentInk)
                    .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var tiles: some View {
        let items = OverallLoader.tiles(stats)
        let perKm = InfoFormula.shownPerKm(stats)
        if typeSize.isAccessibilitySize || perKm == nil {
            // big text: one tile per row; no fuel price: no money tile
            StatTileGrid {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in StatTile(value: t.value, label: t.label) }
            }
            if let perKm { SavedPerKmTile(perKm: perKm, stats: stats).padding(.top, DS.Space.row) }
        } else {
            // three tiles on the first row; the fourth (CO₂) and the wide tile on the second
            VStack(spacing: DS.Space.row) {
                // each tile gets room for its own value (a short number stays narrow)
                StatTileGrid(weighted: true) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, t in StatTile(value: t.value, label: t.label) }
                }
                StatTileGrid(weighted: true) {
                    ForEach(Array(items.dropFirst(3).enumerated()), id: \.offset) { _, t in StatTile(value: t.value, label: t.label).tileWeight(1) }
                    SavedPerKmTile(perKm: perKm ?? 0, stats: stats).tileWeight(2)
                }
            }
        }
    }
}

/// F-20: lifetime net saved ÷ lifetime km, a wide tile that stands out: orange value on a faint orange tint, a small label under it and
/// an ⓘ with how it is worked out.
struct SavedPerKmTile: View {
    let perKm: Double
    let stats: OverallStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(OverallCalc.perKmText(perKm))
                    .scaledFont(28, weight: .semibold, mono: true, relativeTo: .title)
                    .foregroundStyle(Theme.accentInk)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("/ km saved").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accentInk).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                InfoButton("Saved per km", info: InfoFormula.perKm(stats))
            }
            Text("every km by scooter instead of car").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .glassCard(radius: DS.Radius.tile, tint: Theme.accent, padding: 12)
        .accessibilityElement(children: .combine)
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
        let rolling = name == "stats-rolling"
        let month = name == "stats-month" || rolling
        let empty = name == "stats-empty"
        let firstWeek = name == "stats-first-week"
        let now: Int64 = 1_790_000_000_000
        let period = StatsCalc.period(span: month ? .month : .week, mode: rolling ? .rolling : .calendar, nowMs: now, utcOffsetMin: 180)
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
        var model = StatsModel(span: month || rolling ? .month : .week, mode: rolling ? .rolling : .calendar, period: period, totals: t, comparisonPct: empty || firstWeek ? nil : 12,
                               holidayTagged: false, recent: insights, electricityIlsPerKwh: 0.64, fuelLPer100km: 7, fuelPriceIls: 8.27, packWh: 800,
                               lastWeek: week, pastWeeks: empty ? [] : WeekPreview.weeks())
        model.weekBars = empty ? [] : WeekPreview.bars()
        model.overall = empty ? nil : overall()
        model.insights = empty ? InsightBoard(cards: [], learning: []) : InsightsPreview.board()
        if firstWeek { model.firstWeekNote = "First week \u{00B7} from Wed 7 Oct" }
        return model
    }
}

// MARK: Past weeks

/// P6-5: the switch above the Past weeks chart, km / rides / time / \u{20AA} saved, with the sliding pill of the tab bar and Load; remembered.
struct PastWeeksSwitch: View {
    @AppStorage(PastWeeksMetric.settingKey) private var metricRaw = PastWeeksMetric.km.rawValue

    var body: some View {
        GlassSegmented(options: PastWeeksMetric.allCases.map { ($0.rawValue, $0.switchTitle) },
                       selection: Binding(get: { metricRaw }, set: { metricRaw = $0 }), slidingPill: true)
            .accessibilityLabel("What the chart shows")
    }
}

/// ST10 + P6-5: one value per finished week as bars, oldest on the left, newest at the right edge. Each bar carries its value on top ("61 km")
/// and its week label below ("6 Sep"), so it is always clear what is measured; empty weeks are a thin bar with 0. More weeks than fit scroll
/// sideways. Drawn with plain views (not Charts) so the labels sit exactly on the bars.
struct PastWeeksChart: View {
    let bars: [WeekBar]
    var metric: PastWeeksMetric = .km
    var height: CGFloat = 180
    var utcOffsetMin = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let slot: CGFloat = 50
    private let labelBand: CGFloat = 44

    var body: some View {
        let ordered = bars.sorted { $0.start < $1.start }   // B33: one slot per week, empty weeks are 0
        let top = max(ordered.map { metric.value($0) }.max() ?? 0, 0.0001)
        let barArea = max(40, height - labelBand)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(ordered, id: \.start) { bar in
                    let v = metric.value(bar)
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(metric.valueText(bar))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(v > 0 ? Color.primary : Color.secondary)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.accent)
                            .frame(height: max(3, barArea * CGFloat(v / top)))
                        Text(PastWeeksMetric.weekLabel(start: bar.start, utcOffsetMin: utcOffsetMin))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: slot, height: height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Week of \(PastWeeksMetric.weekLabel(start: bar.start, utcOffsetMin: utcOffsetMin)), \(metric.valueText(bar))")
                }
            }
            .padding(.horizontal, 2)
            .frame(minWidth: 0, alignment: .trailing)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: metric)
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(metric.cardTitle), bar chart")
    }
}

/// The finished weeks before the last one, newest first, as a compact table (made live from the rides; weeks under 2 riding days
/// have no summary).
struct PastWeeksView: View {
    var weeks: [InsightRunner.PastWeek]
    var bars: [WeekBar] = []
    var utcOffsetMin = 0
    @AppStorage(PastWeeksMetric.settingKey) private var metricRaw = PastWeeksMetric.km.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.row) {
                if weeks.isEmpty && bars.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No weeks yet").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .glassCard(radius: DS.Radius.hero, padding: 0)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PastWeeksMetric.from(stored: metricRaw).cardTitle).font(.subheadline.weight(.semibold))
                        PastWeeksSwitch()
                        PastWeeksChart(bars: bars, metric: PastWeeksMetric.from(stored: metricRaw), height: 260, utcOffsetMin: utcOffsetMin)
                    }
                    .padding(DS.Space.cardPad)
                    .glassCard(padding: 0)
                    if !weeks.isEmpty { table }
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
    /// made-up weeks on real week starts (a Sunday, 7 days apart) so the labels read like dates
    static func bars() -> [WeekBar] {
        let week: Int64 = 7 * 86_400_000
        let first: Int64 = 1_787_443_200_000   // a Sunday in 2026
        let data: [(Double, Int, Double, Double?)] = [(22, 3, 4_500, 18), (40, 6, 7_800, 33), (0, 0, 0, 0), (61, 8, 11_400, 52), (35, 5, 6_600, 29), (48, 7, 9_300, 41)]
        return data.enumerated().map { i, d in WeekBar(start: first + Int64(i) * week, km: d.0, rides: d.1, seconds: d.2, savedIls: d.3) }
    }

    static func weeks() -> [InsightRunner.PastWeek] {
        [InsightRunner.PastWeek(start: 1, title: "Week of 20 Sep", lines: [], km: 61, rides: 8),
         InsightRunner.PastWeek(start: 2, title: "Week of 13 Sep", lines: [], km: 40, rides: 6),
         InsightRunner.PastWeek(start: 3, title: "Week of 6 Sep", lines: [], km: 22, rides: 3)]
    }
}
