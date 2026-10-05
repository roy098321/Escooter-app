import Charts
import CorckieCore
import SwiftUI

/// M4-07: the Stats tab (IA: Stats). Recent insights on top, Week / Month with Calendar / Rolling, totals, full charges used and
/// electricity cost (M35), fuel money saved (M35b, manual fuel price), km per day. Numbers are made in CorckieCore (`StatsCalc`,
/// unit tested); this view draws them. No records, goals or streaks (P-3).
struct StatsView: View {
    var preview: StatsModel?

    @AppStorage("stats.span") private var spanRaw = StatsSpan.week.rawValue
    @AppStorage("stats.mode") private var modeRaw = StatsMode.calendar.rawValue
    @State private var back = 0
    @State private var model: StatsModel?

    private var span: StatsSpan { StatsSpan(rawValue: spanRaw) ?? .week }
    private var mode: StatsMode { StatsMode(rawValue: modeRaw) ?? .calendar }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let m = preview ?? model {
                    content(m)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { CostSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Prices")
                }
            }
            .onAppear(perform: load)
            .onChange(of: spanRaw) { _, _ in back = 0; load() }
            .onChange(of: modeRaw) { _, _ in back = 0; load() }
            .onChange(of: back) { _, _ in load() }
            .screen("Stats")
        }
    }

    private func content(_ m: StatsModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            recentCard(m)
            weekCards(m)
            if preview == nil {
                Picker("Span", selection: $spanRaw) {
                    ForEach(StatsSpan.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Mode", selection: $modeRaw) {
                    ForEach(StatsMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } else {
                Text("\(m.span.title) · \(m.mode.title)").font(.footnote).foregroundStyle(.secondary)
            }
            periodHeader(m)
            if m.totals.isEmpty {
                ContentUnavailableView("No rides in this period", systemImage: "chart.bar",
                                       description: Text("Totals, charges and costs appear after your first ride."))
                    .frame(maxWidth: .infinity)
            } else {
                if let text = StatsLoader.comparisonText(m) {
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(StatsLoader.tiles(m).enumerated()), id: \.offset) { _, t in tile(t.label, t.value, t.note) }
                }
                bars(m)
            }
            if preview == nil {
                NavigationLink { FactorsView() } label: {
                    HStack {
                        Label("What affects my rides", systemImage: "wind")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private func periodHeader(_ m: StatsModel) -> some View {
        HStack {
            if m.mode == .calendar || m.period.dayCount > 0 {
                Button { back += 1 } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Earlier")
                    .disabled(preview != nil)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(m.period.label).font(.headline)
                if m.holidayTagged { Text("Holiday week").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { back = max(0, back - 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Later")
                .disabled(back == 0 || preview != nil)
        }
    }

    private func recentCard(_ m: StatsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent insights").font(.headline)
            if m.recent.isEmpty {
                Text("Nothing yet. Insights appear after rides on the same route.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(m.recent.enumerated()), id: \.offset) { i, ins in
                    if item.offset > 0 { Divider() }
                    Text(item.element.text).font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tile(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bars(_ m: StatsModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Distance per day").font(.footnote).foregroundStyle(.secondary)
            Chart(Array(m.totals.barsKm.enumerated()), id: \.offset) { i, km in
                BarMark(x: .value("Day", item.offset + 1), y: .value("km", item.element))
                    .foregroundStyle(.tint)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
            .frame(height: 140)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                Text("Electricity price (\u{20AA} per kWh)")
            } footer: {
                Text("Used for \"Electricity\" on Stats: full charges used x battery size x this price. Default 0.64.")
            }
            Section {
                TextField("7", text: $fuelUse).keyboardType(.decimalPad)
            } header: {
                Text("Car fuel use (L per 100 km)")
            } footer: {
                Text("\"Fuel saved\" = the same distance by car at this use and the fuel price (Settings \u{2192} Costs) minus the electricity of the ride. Default 7.")
            }
        }
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
        try? StatsQueries(db).setNumber(key, v)
    }
}

/// Made-up numbers for the CI ui-shots (`-uiShot stats-week`, `stats-month`, `stats-empty`).
enum StatsPreview {
    static func model(_ name: String) -> StatsModel {
        let month = name == "stats-month"
        let empty = name == "stats-empty"
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
            t.barsKm = (0..<period.dayCount).map { i in i % 7 == 5 || i % 7 == 6 ? 0 : 6 + Double((i * 5) % 9) }
        } else {
            t.barsKm = [Double](repeating: 0, count: period.dayCount)
        }
        let week = name == "week-card" ? [Insight(type: .q22Weekly, weekStart: now, text: "Last week: 58 km, 9 rides, 3 h 8 min, +6 km more than the week before. Wind cost you about 4 min over the week.", basedOnN: 9, createdAt: now)] : []
        let insights = empty ? [] : [
            Insight(type: .q15After, rideId: "p1", routeId: "A", text: "Tailwind saved you ~1.5 min and ~1% battery today.", basedOnN: 9, createdAt: now),
            Insight(type: .q4After, rideId: "p2", routeId: "A", text: "1:10 min slower than usual: headwind (~1:00 min).", basedOnN: 8, createdAt: now - 86_400_000),
        ]
        return StatsModel(span: month ? .month : .week, mode: .calendar, period: period, totals: t, comparisonPct: empty ? nil : 12, holidayTagged: false,
                          recent: insights, electricityIlsPerKwh: 0.64, fuelLPer100km: 7, fuelPriceIls: 8.27, packWh: 800, lastWeek: week,
                          pastWeeks: name == "week-card" ? WeekPreview.weeks() : [])
    }
}

// MARK: M4-09: week card + past weeks

extension StatsView {
    fileprivate func weekCards(_ m: StatsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !m.lastWeek.isEmpty || !m.thisWeek.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weekly summary").font(.headline)
                    ForEach(Array((m.lastWeek + m.thisWeek).enumerated()), id: \.offset) { item in
                        if item.offset > 0 { Divider() }
                        Text(item.element.text).font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !m.pastWeeks.isEmpty {
                NavigationLink { PastWeeksView(weeks: m.pastWeeks) } label: {
                    HStack {
                        Label("Past weeks", systemImage: "calendar")
                        Spacer()
                        Text("\(m.pastWeeks.count)").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The finished weeks before the last one, newest first (made live from the rides; weeks under 2 riding days have no summary).
struct PastWeeksView: View {
    var weeks: [InsightRunner.PastWeek]

    var body: some View {
        List {
            if weeks.isEmpty {
                Text("No past weeks yet. A week needs rides on 2 different days.").foregroundStyle(.secondary)
            }
            ForEach(weeks) { w in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(w.lines.enumerated()), id: \.offset) { item in
                        Text(item.element).font(item.offset == 0 ? .subheadline.weight(.semibold) : .footnote)
                            .foregroundStyle(item.offset == 0 ? .primary : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Past weeks")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Past weeks")
    }
}

enum WeekPreview {
    static func weeks() -> [InsightRunner.PastWeek] {
        [InsightRunner.PastWeek(start: 1, title: "Week of 20 Sep", lines: ["Week of 20 Sep: 61 km, 8 rides, 3 h 2 min, +6 km more than the week before.", "Wind cost you about 4 min over the week."]),
         InsightRunner.PastWeek(start: 2, title: "Week of 13 Sep", lines: ["Week of 13 Sep: 40 km, 6 rides, 2 h 10 min."]),
         InsightRunner.PastWeek(start: 3, title: "Week of 6 Sep", lines: ["Week of 6 Sep: 22 km, 3 rides, 1 h 5 min."])]
    }
}
