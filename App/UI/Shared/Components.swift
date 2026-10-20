import CorckieCore
import SwiftUI

// P6-2 shared building blocks (F-11 declutter + F-15 theme v2). The screens are rebuilt from these in the next chunks:
// numbers as tiles, facts as chips, the state as one pill, small brown section labels, explanations behind an ⓘ (G1).
// Each one draws only with `Theme` tokens and keeps working in sunlight mode and at large Dynamic Type.

// MARK: StatTile

/// A number tile: big rounded value + a one-word label under it, on a sand card. Optional small ▲ / ▼ chip (`trend`).
/// No explanation lines: put those behind an `InfoButton`. (`note` is kept only for the Stats screen until its declutter
/// in chunk 3; new screens leave it out.)
///
///     StatTile(value: "58 km", label: "Distance")
///     StatTile(value: "9", label: "Rides", trend: .up("2"))
struct StatTile: View {
    enum Trend: Equatable {
        case up(String)
        case down(String)
    }

    let value: String
    let label: String
    var tint: Color?
    var trend: Trend?
    var note: String?
    /// true = the value in the accent orange (a highlighted number; only for large values, see Theme)
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .scaledFont(22, weight: .semibold, mono: true, relativeTo: .title2)
                    .foregroundStyle(highlighted ? Theme.accentInk : Color.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .aliveNumber(value)
            }
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let trend { TrendChip(trend: trend) }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .glassCard(radius: DS.Radius.tile, tint: tint, padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, value, trend.map(Self.spoken), note].compactMap { $0 }.joined(separator: ", "))
    }

    private static func spoken(_ t: Trend) -> String {
        switch t {
        case .up(let s): return "up \(s)"
        case .down(let s): return "down \(s)"
        }
    }
}

/// The small ▲ / ▼ chip of a `StatTile`: neutral sand, no judgement colour (a change is not good or bad by itself, P-3).
struct TrendChip: View {
    let trend: StatTile.Trend

    var body: some View {
        let (arrow, text): (String, String) = {
            switch trend {
            case .up(let s): return ("arrowtriangle.up.fill", s)
            case .down(let s): return ("arrowtriangle.down.fill", s)
            }
        }()
        HStack(spacing: 2) {
            Image(systemName: arrow).font(.system(size: 7, weight: .bold))
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Theme.chip, in: Capsule())
        .foregroundStyle(Theme.muted)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Adaptive grid of tiles: 3 columns at normal size, fewer at large Dynamic Type.
/// `weighted: true` makes one row whose tiles share the width by `.tileWeight(_:)` (default: their own content width), so a tile with a
/// long value ("4 h 5 min") gets room and one with a short value ("9") stays narrow; at accessibility sizes it wraps like the plain grid.
struct StatTileGrid<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var minTile: CGFloat = 100
    @Environment(\.dynamicTypeSize) private var typeSize
    private let weighted: Bool
    private let content: Content
    init(weighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.weighted = weighted
        self.content = content()
    }

    var body: some View {
        if weighted && !typeSize.isAccessibilitySize {
            WeightedTileRow(spacing: DS.Space.row) { content }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile), spacing: DS.Space.row)], spacing: DS.Space.row) {
                content
            }
        }
    }
}

private struct TileWeightKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

extension View {
    /// Share of the row width for this tile in a weighted `StatTileGrid` (nil = its content width)
    func tileWeight(_ weight: CGFloat) -> some View { layoutValue(key: TileWeightKey.self, value: weight) }
}

/// One row; each tile gets its weighted share of the width, but never less than its content needs while the others have room to give.
private struct WeightedTileRow: Layout {
    var spacing: CGFloat

    private func widths(_ subviews: Subviews, _ total: CGFloat) -> [CGFloat] {
        guard !subviews.isEmpty else { return [] }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let weights = zip(subviews, ideal).map { $0.0[TileWeightKey.self] ?? $0.1 }
        let avail = max(total - spacing * CGFloat(subviews.count - 1), 0)
        let sum = max(weights.reduce(0, +), 0.001)
        var w = weights.map { avail * $0 / sum }
        let deficit = zip(w, ideal).reduce(CGFloat(0)) { $0 + max(0, $1.1 - $1.0) }
        let slack = zip(w, ideal).reduce(CGFloat(0)) { $0 + max(0, $1.0 - $1.1) }
        if deficit > 0, slack > 0 {
            let take = min(deficit, slack)
            for i in w.indices {
                if ideal[i] > w[i] { w[i] += (ideal[i] - w[i]) * take / deficit }
                else { w[i] -= (w[i] - ideal[i]) * take / slack }
            }
        }
        return w
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        let w = widths(subviews, total)
        let h = zip(subviews, w).map { $0.0.sizeThatFits(ProposedViewSize(width: $0.1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(subviews, bounds.width)
        var x = bounds.minX
        for (s, width) in zip(subviews, w) {
            s.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: InfoChip

/// One fact as a small chip: SF Symbol + a short text ("⏱ 13 min", "🏁 8:56", "🔋 11%"). Sand fill, never wraps.
///
///     InfoChip("timer", "13 min")
///     InfoChip("flag.checkered", "8:56", label: "Arrive")
struct InfoChip: View {
    let symbol: String
    let text: String
    /// VoiceOver name of the fact (the symbol alone says nothing); defaults to the text
    var label: String?

    init(_ symbol: String, _ text: String, label: String? = nil) {
        self.symbol = symbol
        self.text = text
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Theme.canyon)
            Text(text).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.chip, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "\($0), \(text)" } ?? text)
    }
}

// MARK: StatusPill

/// The state of something in one line: a coloured icon + a short text, and optionally a big value on the right
/// (Home: "● Connected · 91%"). Replaces the status cards that repeated the button (H3).
///
///     StatusPill(symbol: "circle.fill", text: "Connected", tint: Theme.ok, value: "91%")
struct StatusPill: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.accent
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.subheadline).lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .scaledFont(24, weight: .bold, mono: true, relativeTo: .title2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .aliveNumber(value)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: DS.hit)
        .glassCard(radius: 26, padding: 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(text), \($0)" } ?? text)
    }
}

// MARK: SectionHeader

/// A small uppercase section label in the theme's brown ("THIS WEEK", "MONEY"). No subtitle line under it (G1).
///
///     SectionHeader("This week")
///     SectionHeader("Money") { InfoButton("Money", text: "Saved = fuel you did not buy minus the electricity.") }
struct SectionHeader<Trailing: View>: View {
    let title: String
    private let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.sectionLabel)
                .accessibilityAddTraits(.isHeader)
            trailing
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: InfoButton

/// The ⓘ that holds an explanation instead of grey text under a card (G1, owner: "delete; if truly needed, behind an ⓘ").
/// Tap: a small sheet with the title and the text (a popover-sized sheet, so it works the same on every iPhone).
///
///     InfoButton("Battery per km", text: "Rested battery at the start minus at the end, divided by the distance.")
struct InfoButton: View {
    let title: String
    let info: InfoContent
    @State private var open = false

    init(_ title: String, info: InfoContent) {
        self.title = title
        self.info = info
    }

    /// A lead line only (no formula): kept for the places that have nothing to calculate
    init(_ title: String, text: String) {
        self.init(title, info: InfoContent(lead: text))
    }

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.canyon)
                .frame(minWidth: DS.hit, minHeight: DS.hit / 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .sheet(isPresented: $open) {
            InfoSheet(title: title, info: info)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.background)
                .presentationCornerRadius(DS.Radius.hero)
        }
    }
}

/// F-25: every info sheet looks the same: title, one lead line, a formula box (aligned rows, a bold accent result row), "Based on" rows
/// (a row opens the screen where the value is set, when it can be set) and at most one caveat sentence.
///
///     InfoSheet(title: "Money", info: InfoFormula.money(grossIls: 145.74, electricityIls: 0.27, km: 126, lPer100: 14, rate: 0.64, charges: 0.5))
struct InfoSheet: View {
    let title: String
    let info: InfoContent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.headline).fontDesign(.rounded)
                    Text(info.lead).font(.body).fixedSize(horizontal: false, vertical: true)
                    if !info.formula.isEmpty { formulaBox }
                    if !info.basedOn.isEmpty { basedOnBox }
                    if let caveat = info.caveat {
                        Text(caveat).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var formulaBox: some View {
        VStack(spacing: 0) {
            ForEach(Array(info.formula.enumerated()), id: \.offset) { _, row in
                if row.role == .result { Divider().padding(.vertical, 6) }
                HStack(alignment: .firstTextBaseline) {
                    Text(prefix(row.role) + row.label).lineLimit(2)
                    Spacer(minLength: 12)
                    Text(row.text).monospacedDigit()
                }
                .font(row.role == .result ? .body.weight(.bold) : .body)
                .foregroundStyle(row.role == .result ? Theme.accentInk : Color.primary)
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DS.Space.cardPad)
        .frame(maxWidth: .infinity)
        .glassCard(padding: 0)
    }

    private func prefix(_ role: InfoRole) -> String {
        switch role {
        case .minus: return "\u{2212} "
        case .plus: return "+ "
        case .divide: return "\u{00F7} "
        case .result: return "= "
        case .start: return ""
        }
    }

    private var basedOnBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BASED ON").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(Theme.sectionLabel)
            VStack(spacing: 0) {
                ForEach(Array(info.basedOn.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider() }
                    if let link = row.link {
                        NavigationLink {
                            switch link {
                            case .costSettings: CostSettingsView()
                            case .priceHistory: PriceHistoryView()
                            }
                        } label: { basedOnRow(row, chevron: true) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens where it is set")
                    } else {
                        basedOnRow(row, chevron: false)
                    }
                }
            }
            .padding(.horizontal, DS.Space.cardPad)
            .glassCard(padding: 0)
        }
    }

    private func basedOnRow(_ row: InfoBasedOn, chevron: Bool) -> some View {
        HStack {
            Text(row.label).font(.subheadline)
            Spacer(minLength: 12)
            Text(row.value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            if chevron { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: InfoBox, Pill

/// The tinted explanation box (accent 12 %). Being phased out by the declutter (G1): prefer an `InfoButton`.
struct InfoBox: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.cardPad)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A small text badge. Filled = dark text on the colour (readable on the orange); not filled = sand chip with the text in `tint`.
struct Pill: View {
    let text: String
    var tint: Color = Theme.accentInk
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(filled ? tint : Theme.chip, in: Capsule())
            .foregroundStyle(filled ? Theme.onAccent : tint)
    }
}

/// A1 (F-19): a number that changes rolls its changed digits (Apple numericText, smooth). Reduce Motion: a plain cross-fade.
struct AliveNumber: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: value)
    }
}

extension View {
    func aliveNumber(_ value: String) -> some View { modifier(AliveNumber(value: value)) }
}
