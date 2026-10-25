import Charts
import CorckieCore
import SwiftUI

/// F-21 colours of the insight chips and the "what if" figures (built with the Theme's dynamic colour, light and dark)
enum InsightStyle {
    static let patternInk = Theme.dynamic(light: 0x3F7A4A, dark: 0x9DBF8A)
    static let patternFill = Theme.dynamic(light: 0xDDEBD9, dark: 0x2A3626)
    static let maintenanceInk = Theme.dynamic(light: 0x3E5C80, dark: 0xA9C4E6)
    static let maintenanceFill = Theme.dynamic(light: 0xDCE6F2, dark: 0x263445)
    static let worse = Theme.dynamic(light: 0xB8405A, dark: 0xE8A0B0)
    static let dot = Theme.dynamic(light: 0x5A3A22, dark: 0xF6E7D3)

    static func ink(_ kind: InsightCard.Kind) -> Color {
        switch kind {
        case .today: return Theme.onAccent
        case .pattern: return patternInk
        case .maintenance: return maintenanceInk
        }
    }

    static func fill(_ kind: InsightCard.Kind) -> Color {
        switch kind {
        case .today: return Theme.accent
        case .pattern: return patternFill
        case .maintenance: return maintenanceFill
        }
    }

    static func tone(_ t: WhatIfTone) -> Color {
        switch t {
        case .better: return patternInk
        case .worse: return worse
        case .neutral: return Color.primary
        }
    }
}

/// TODAY / PATTERN / MAINTENANCE
struct InsightChip: View {
    let kind: InsightCard.Kind

    var body: some View {
        Text(kind.chip)
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(InsightStyle.ink(kind))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(InsightStyle.fill(kind), in: Capsule())
    }
}

/// F-21 card: chip, headline, the one big number with its context, the one action, "Based on N rides". Tap = the detail page.
struct InsightCardView: View {
    let card: InsightCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InsightChip(kind: card.kind)
            Text(card.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { number; context }
                VStack(alignment: .leading, spacing: 2) { number; context }
            }
            Text("\u{2192} " + card.action)
                .font(.body)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Text(card.basedOn).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: DS.Radius.hero, tint: card.kind == .today ? Theme.accent : nil, padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens how this was worked out")
    }

    private var number: some View {
        Text("\(card.value) \(card.unit)")
            .scaledFont(40, weight: .semibold, relativeTo: .largeTitle)
            .foregroundStyle(Theme.accentInk)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var context: some View {
        Text(card.context).font(.headline).foregroundStyle(.secondary).lineLimit(2)
    }
}

/// F-21 Stats section: at most 3 cards (only Medium / High certainty) and an optional quiet "Still learning" line.
struct InsightsSection: View {
    let board: InsightBoard

    var body: some View {
        if !board.progress.isEmpty || !board.pages.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Insights")
                VStack(alignment: .leading, spacing: DS.Space.row) {
                    // Note 9: confident insights are pages of their own (the bar is gone)
                    ForEach(board.pages) { entry in
                        NavigationLink { InsightDetailView(card: entry.card).navigationTitle(entry.page.rawValue) } label: { InsightPageRow(entry: entry) }
                            .buttonStyle(.plain)
                    }
                    ForEach(board.progress) { p in
                        if let c = p.card {
                            NavigationLink { InsightDetailView(card: c) } label: { InsightProgressCard(progress: p, tappable: true) }
                                .buttonStyle(.plain)
                        } else {
                            InsightProgressCard(progress: p, tappable: false)
                        }
                    }
                }
            }
        }
    }
}

/// Note 9: one graduated insight page in the Stats list ("Speed · Sweet spot between 26 and 30 km/h")
struct InsightPageRow: View {
    let entry: InsightPageEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.page.symbol).foregroundStyle(Theme.accentInk).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.page.rawValue).font(.headline)
                Text(entry.card.headline).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

/// Note 9: an insight on its way: title, the early read's range (tagged), a bar with the early read and confident marks, the count
struct InsightProgressCard: View {
    let progress: InsightProgress
    var tappable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.title).font(.headline)
                Spacer(minLength: 8)
                if progress.stage == .early {
                    Text("early read").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
            }
            if let range = progress.range {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(range).scaledFont(30, weight: .semibold, relativeTo: .title).lineLimit(1).minimumScaleFactor(0.6)
                    if let ctx = progress.rangeContext { Text(ctx).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
            } else {
                Text("No answer yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressMarks(fraction: progress.fraction, earlyMark: progress.earlyMark)
            Text(progress.countLine).font(.footnote).foregroundStyle(.secondary)
            if let w = progress.widenedLine { Text(w).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(tappable ? "Opens how this was worked out" : "")
    }
}

/// The bar with its two marks, "early read" and "confident" under them
struct ProgressMarks: View {
    let fraction: Double
    let earlyMark: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip)
                    Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * fraction))
                    Rectangle().fill(Color.secondary).frame(width: 2, height: 14).offset(x: g.size.width * earlyMark - 1)
                    Rectangle().fill(Color.secondary).frame(width: 2, height: 14).offset(x: g.size.width - 2)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            GeometryReader { g in
                Text("early read").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .position(x: min(g.size.width - 60, max(30, g.size.width * earlyMark)), y: 6)
                Text("confident").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .position(x: g.size.width - 26, y: 6)
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Progress \(Int((fraction * 100).rounded())) percent of the way to confident")
    }
}

/// F-21 Home: the one TODAY card, only when it matters, never during a ride (the caller hides it then); "×" hides it for the day.
struct TodayInsightSlot: View {
    /// the ui-shot card; nil = load the real one
    var preview: InsightCard?
    /// false in previews of Home without a TODAY card
    var live = true
    @AppStorage("insight.today.hiddenDay") private var hiddenDay = ""
    @State private var card: InsightCard?

    static var todayKey: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    var body: some View {
        Group {
            if let c = preview ?? card, preview != nil || hiddenDay != Self.todayKey {
                NavigationLink { InsightDetailView(card: c) } label: { InsightCardView(card: c) }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            if preview == nil { hiddenDay = Self.todayKey }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: DS.hit, height: DS.hit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide for today")
                        .padding(4)
                    }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard preview == nil, live, hiddenDay != Self.todayKey, let db = AppModel.shared.displayDatabase else { return }
        let chosen = RouteFollowSelection.shared.routeId
        DispatchQueue.global(qos: .utility).async {
            let found = InsightBoardLoader.today(db, chosenRouteId: chosen)
            DispatchQueue.main.async { card = found }
        }
    }
}

/// F-21 detail page (detail.png): what it means, the chart of your own data, What if, How we worked it out, How sure, Try this.
struct InsightDetailView: View {
    let card: InsightCard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InsightChip(kind: card.kind)
                Text(card.headline)
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Text(card.meaning)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if let chart = card.chart {
                    SectionHeader(chart.title).padding(.top, 8)
                    InsightChartCard(chart: chart)
                }
                if !card.whatIf.isEmpty {
                    SectionHeader(card.whatIfTitle).padding(.top, 8)
                    whatIf
                }
                SectionHeader("How we worked it out").padding(.top, 8)
                method
                SectionHeader("How sure").padding(.top, 8)
                sure
                SectionHeader("Try this").padding(.top, 8)
                Text("\u{2192} " + card.tryThis)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(radius: DS.Radius.card, padding: 0)
            }
            .padding(DS.Space.gutter)
            .padding(.bottom, 24)
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle(card.kind == .today ? "Today" : "Insight")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Insight detail")
    }

    private var whatIf: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.whatIf.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text(row.label).fontWeight(row.isBaseline ? .semibold : .regular)
                        + Text(row.note.isEmpty ? "" : " " + row.note).font(.subheadline).foregroundStyle(.secondary))
                    Spacer(minLength: 8)
                    items(row).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
            Text(card.whatIfNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .glassCard(radius: DS.Radius.card, padding: 0)
    }

    private func items(_ row: WhatIfRow) -> Text {
        var out = Text("")
        for (i, item) in row.items.enumerated() {
            if i > 0 { out = out + Text(" \u{00B7} ").foregroundStyle(.secondary) }
            out = out + Text(item.text).foregroundStyle(InsightStyle.tone(item.tone)).fontWeight(row.isBaseline ? .semibold : .regular)
        }
        return out
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("From ") + Text(card.evidence.bold).bold() + Text(card.evidence.span.isEmpty ? "" : ", " + card.evidence.span))
                .font(.body)
            Text(card.evidence.exclusions)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(card.method.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.callout, design: .monospaced))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: DS.Radius.card, padding: 0)
    }

    private var sure: some View {
        let level = card.certainty.level
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.chip)
                        Capsule().fill(level == .high ? InsightStyle.patternInk : Theme.accent)
                            .frame(width: geo.size.width * level.meter)
                    }
                }
                .frame(height: 10)
                Text(level.title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(level == .high ? InsightStyle.patternInk : Theme.accentInk)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Certainty \(level.title)")
            Text(card.certainty.interval + " " + card.certainty.agreement)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: DS.Radius.card, padding: 0)
    }
}

/// The chart of the detail page: highlighted band, confidence band, fitted curve (or levels), the rider's own dots.
struct InsightChartCard: View {
    let chart: InsightChart

    private struct Segment: Identifiable {
        var id: Int
        var points: [InsightCurvePoint]
        /// a flat level (two points, same y): drawn as a band with a rule
        var isLevel: Bool { points.count == 2 && abs(points[0].y - points[1].y) < 1e-9 }
    }

    private var segments: [Segment] {
        Dictionary(grouping: chart.curve, by: \.segment).map { Segment(id: $0.key, points: $0.value.sorted { $0.x < $1.x }) }.sorted { $0.id < $1.id }
    }

    var body: some View {
        let yDom = chart.yDomain
        let xDom = chart.xDomain
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                if let band = chart.band {
                    RectangleMark(xStart: .value("x", band.lowerBound), xEnd: .value("x", band.upperBound),
                                  yStart: .value("y", yDom.lowerBound), yEnd: .value("y", yDom.upperBound))
                        .foregroundStyle(Theme.accent.opacity(0.13))
                }
                ForEach(segments) { seg in
                    if seg.isLevel {
                        RectangleMark(xStart: .value("x", seg.points[0].x), xEnd: .value("x", seg.points[1].x),
                                      yStart: .value("y", seg.points[0].lo), yEnd: .value("y", seg.points[0].hi))
                            .foregroundStyle(Theme.accent.opacity(0.22))
                        RuleMark(xStart: .value("x", seg.points[0].x), xEnd: .value("x", seg.points[1].x), y: .value("y", seg.points[0].y))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    } else {
                        ForEach(Array(seg.points.enumerated()), id: \.offset) { _, p in
                            AreaMark(x: .value("x", p.x), yStart: .value("lo", p.lo), yEnd: .value("hi", p.hi))
                                .foregroundStyle(Theme.accent.opacity(0.22))
                                .interpolationMethod(.catmullRom)
                        }
                        ForEach(Array(seg.points.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("s", "fit\(seg.id)"))
                                .foregroundStyle(Theme.accent)
                                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                }
                ForEach(Array(chart.dots.enumerated()), id: \.offset) { _, d in
                    PointMark(x: .value("x", d.x), y: .value("y", d.y))
                        .foregroundStyle(InsightStyle.dot)
                        .symbolSize(44)
                }
            }
            .chartXScale(domain: xDom)
            .chartYScale(domain: yDom)
            .chartXAxis {
                AxisMarks(values: chart.xTicks) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(label(v, ticks: chart.xTicks, labels: chart.xLabels)).font(.caption2) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: chart.yTicks) { value in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(label(v, ticks: chart.yTicks, labels: chart.yLabels)).font(.caption2) }
                    }
                }
            }
            .frame(height: 210)
            .accessibilityLabel(chart.title)
            Text(chart.caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassCard(radius: DS.Radius.card, padding: 0)
    }

    private func label(_ v: Double, ticks: [Double], labels: [String]) -> String {
        guard let i = ticks.indices.min(by: { abs(ticks[$0] - v) < abs(ticks[$1] - v) }), i < labels.count else { return "" }
        return labels[i]
    }
}

/// Made-up insights for the CI ui-shots and previews (the engines run on `InsightSamplesF21`, synthetic only).
enum InsightsPreview {
    static func board() -> InsightBoard {
        let all = InsightSamplesF21.outcomes()
        var b = InsightBoard.make(all)
        let made = InsightProgressBuilder.make(all)
        b.progress = made.progress
        b.pages = made.pages
        return b
    }

    static func learning() -> InsightBoard {
        let all: [InsightOutcome] = [.learning(.sweetSpot, "5 of 12 steady stretches"), .learning(.departure, "2 of 6 rides on your usual route"),
                                     .learning(.creep, "3 of 8 recent rides")]
        return InsightBoard(cards: [], learning: [.sweetSpot, .departure, .creep], progress: InsightProgressBuilder.make(all).progress)
    }

    static func card(_ topic: InsightCard.Topic) -> InsightCard? {
        InsightSamplesF21.outcomes().compactMap(\.card).first { $0.topic == topic }
    }

    /// The ui-shot screens: stats-insights, insights-learning, insight-detail (sweet spot), insight-detail-departure, insight-detail-creep
    @ViewBuilder static func screen(_ name: String) -> some View {
        switch name {
        case "insights-learning":
            ScrollView { InsightsSection(board: learning()).padding(16) }
                .background { MapBackdrop().ignoresSafeArea() }
        case "insight-detail", "insight-detail-departure", "insight-detail-creep", "insight-detail-wind":
            let topic: InsightCard.Topic = name == "insight-detail-departure" ? .departure
                : (name == "insight-detail-creep" ? .creep : (name == "insight-detail-wind" ? .wind : .sweetSpot))
            if let c = card(topic) { InsightDetailView(card: c) } else { Text("No sample card") }
        default:
            ScrollView { InsightsSection(board: board()).padding(16) }
                .background { MapBackdrop().ignoresSafeArea() }
        }
    }
}
