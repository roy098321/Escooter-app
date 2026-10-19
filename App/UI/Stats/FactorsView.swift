import CorckieCore
import SwiftUI

/// M4-08: Stats → "What affects my rides". Per km (all routes pooled) or per trip (one saved route). Each row: the factor, what it
/// costs in time and battery, "based on N rides"; below its gate a progress line instead ("2 of 3 windy rides", pattern D).
/// The words are made in CorckieCore (`FactorsPage`, unit tested).
struct FactorsView: View {
    var preview: [FactorsRow]?

    struct RouteChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @State private var perTrip = false
    @State private var routes: [RouteChoice] = []
    @State private var routeId: String?
    @State private var rows: [FactorsRow] = []

    var body: some View {
        List {
            if preview == nil {
                Section {
                    Picker("View", selection: $perTrip) {
                        Text("Per km").tag(false)
                        Text("Per trip").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if perTrip {
                        if routes.isEmpty {
                            Label("No saved routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.secondary)
                        } else {
                            Picker("Route", selection: $routeId) {
                                ForEach(routes) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
                .glassRows()
            }
            Section {
                let shown = preview ?? rows
                if shown.isEmpty {
                    Label("No effects yet", systemImage: "wind").foregroundStyle(.secondary)
                }
                ForEach(shown) { row in rowView(row, scale: BarScale(shown)) }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("What affects my rides")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: perTrip) { _, _ in load() }
        .onChange(of: routeId) { _, _ in load() }
        .screen("Factors")
    }

    /// The biggest effect on the page, so the bars of all rows share one scale
    struct BarScale {
        var time: Double
        var used: Double
        init(_ rows: [FactorsRow]) {
            time = max(1, rows.compactMap { $0.timeS.map(abs) }.max() ?? 1)
            used = max(0.01, rows.compactMap { $0.usedPct.map(abs) }.max() ?? 0.01)
        }
    }

    /// ST11: one row per factor, two small bars (time, battery); no "based on N"
    private func rowView(_ row: FactorsRow, scale: BarScale) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.title).font(.headline)
                if row.uncertain { Image(systemName: "questionmark.circle").foregroundStyle(Theme.accentInk).accessibilityLabel("Uncertain") }
            }
            if let t = row.timeText { barLine("timer", t, row.timeS, scale.time) }
            if let b = row.batteryText { barLine("battery.50percent", b, row.usedPct, scale.used) }
            if let p = row.progress {
                Label(p, systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            } else if !row.hasEffect, let n = row.basedOn {
                Text(n).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func barLine(_ symbol: String, _ text: String, _ value: Double?, _ scale: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Theme.canyon).frame(width: 18)
            GeometryReader { geo in
                let width = geo.size.width * min(1, abs(value ?? 0) / scale)
                Capsule().fill(Theme.chip)
                    .overlay(alignment: .leading) { Capsule().fill((value ?? 0) < 0 ? Theme.ok : Theme.accent).frame(width: max(4, width)) }
            }
            .frame(height: 6)
            Text(text).font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).frame(width: 130, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        if routes.isEmpty {
            routes = ((try? RouteQueries(db).routes()) ?? []).filter { $0.state == "saved" }
                .map { RouteChoice(id: $0.id, name: RouteService.title(routeId: $0.id, database: db)) }
        }
        var counts: [SmartAnswer: Int] = [:]
        for a in SmartAnswer.allCases { counts[a] = SmartPromptService.answerCount(db, a) }
        if perTrip {
            if routeId == nil { routeId = routes.first?.id }
            rows = routeId.map { FactorsPage.rows(FactorEffects.forRoute(db, routeId: $0)) } ?? []
        } else {
            rows = FactorsPage.rows(FactorEffects.forPooled(db)) + FactorsPage.answerRows(counts: counts)
        }
    }
}

/// Made-up rows for the CI ui-shots (`-uiShot factors`, `factors-sparse`).
enum FactorsPreview {
    static func rows(_ name: String) -> [FactorsRow] {
        func e(_ id: String, _ level: String, _ q: FactorQuantity, _ v: Double?, n: Int, w: Int) -> FactorEffect {
            InsightSamples.effect(id, level, q, v, n: n, nWithout: w, scope: .pooled)
        }
        if name == "factors-sparse" {
            return FactorsPage.rows([e("W1", "head", .time, nil, n: 2, w: 5), e("W3", "wet", .time, nil, n: 1, w: 9), e("T1", "rush", .time, nil, n: 3, w: 2)])
        }
        return FactorsPage.rows([e("W1", "head", .time, 9, n: 14, w: 22), e("W1", "head", .used, 0.35, n: 14, w: 22),
                                 e("W3", "wet", .time, 6, n: 5, w: 30), e("W3", "wet", .used, 0.2, n: 5, w: 30),
                                 e("T1", "rush", .time, 5, n: 18, w: 12), e("R1", "hilly", .used, 0.3, n: 9, w: 25),
                                 e("L1", "perKg", .used, 0.04, n: 4, w: 30), e("W1", "tail", .time, nil, n: 2, w: 20)])
    }
}
