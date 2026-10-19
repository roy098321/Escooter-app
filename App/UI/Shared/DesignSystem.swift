import SwiftUI
import UIKit

/// UI overhaul (UI_PLAN section 1), theme v2 (F-15): spacing, radii, the card, the grouped-list look and the small controls.
/// Colours come from `Theme` (Theme.swift); the reusable building blocks for the screens (StatTile, InfoChip, StatusPill,
/// SectionHeader, InfoButton) are in Components.swift. Sunlight mode turns cards into white panels with a hairline (C30).
/// The live ride view keeps its own `GlassCard` and fixed sizes; nothing here changes its numbers.
enum DS {
    enum Space {
        /// page gutter
        static let gutter: CGFloat = 16
        /// gap between rows of cards
        static let row: CGFloat = 8
        /// gap between blocks
        static let block: CGFloat = 12
        static let cardPad: CGFloat = 14
    }

    enum Radius {
        static let card: CGFloat = 20
        /// hero cards, sheets, big tiles
        static let hero: CGFloat = 28
        static let tile: CGFloat = 18
    }

    /// minimum tap target
    static let hit: CGFloat = 44
}

// MARK: Card

private struct GlassCardStyle: ViewModifier {
    @Environment(\.sunlight) private var sunlight
    let radius: CGFloat
    let tint: Color?
    let padding: CGFloat
    let thin: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background {
                ZStack {
                    // F-15: a matte sand card (dark grey in dark mode), no frosted glass; white with a hairline in sunlight
                    shape.fill(sunlight ? Theme.row : Theme.card)
                    if let tint { shape.fill(tint.opacity(sunlight ? 0.2 : 0.14)) }
                }
            }
            .overlay {
                if sunlight { shape.strokeBorder(Color(.separator), lineWidth: 0.5) }
            }
    }
}

extension View {
    /// The card of theme v2: faint sand (#F8F3EB) / dark grey (#1F1F1F), optional tint; white with a hairline in sunlight.
    /// (The name stays from the glass look so the screens did not change; `thin` is kept for call-site compatibility.)
    func glassCard(radius: CGFloat = DS.Radius.card, tint: Color? = nil, padding: CGFloat = DS.Space.cardPad, thin: Bool = false) -> some View {
        modifier(GlassCardStyle(radius: radius, tint: tint, padding: padding, thin: thin))
    }

    /// Task-sheet style (Compare picker, Merge, Trim, Replay, check guide): standard iOS sheet with detents and a drag indicator
    /// on the page colour, radius 28. Map screens do not use this: they are a fixed map with a normal scroll view below (`MapScreen`, B29).
    func glassPresentation(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.background)
            .presentationCornerRadius(DS.Radius.hero)
    }
}

// MARK: Round glass icon button

/// The look of a round glass icon (40 pt disc inside a 44 pt hit area); use as a label or inside `GlassIconButton`.
struct GlassIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .sunPanel(Circle(), thin: true)
            .frame(width: DS.hit, height: DS.hit)
            .contentShape(Circle())
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { GlassIcon(symbol: symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

// MARK: Segmented glass control

/// A glass segmented control for 2 to 4 options (replaces menu pickers).
struct GlassSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(options[i].1).lineLimit(1).minimumScaleFactor(0.5)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Theme.background : Color.clear, in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.chip, in: Capsule())
    }
}

// MARK: Grouped list (Settings, Developer and the other list screens)

/// Row background of the list screens (F-15, owner answer 1): Apple's inset-grouped layout in theme colours, white rows on a very
/// light warm page in light mode, #1F1F1F rows on #121212 in dark mode. No frosted glass, no grey #F2F2F7.
private struct GlassRowBackground: View {
    var body: some View { Theme.row }
}

private struct GlassListLook: ViewModifier {
    @Environment(\.sunlight) private var sunlight

    func body(content: Content) -> some View {
        // G3: small inline titles; sunlight is the same look with heavier text (bold legibility is set at the root)
        content
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .fontWeight(sunlight ? .semibold : nil)
            .textCase(nil)
            .stiffBounce()
    }
}

extension View {
    /// A standard `List` / `Form` of a list screen: Apple inset-grouped in the theme colours, small inline title.
    func glassList() -> some View {
        modifier(GlassListLook())
    }

    /// Row background for the content it is put on (a `Section`, or a few rows).
    func glassRows() -> some View {
        listRowBackground(GlassRowBackground())
    }
}

/// A list row with a title above a glass segmented control (2 to 4 options).
struct SegmentedRow<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            GlassSegmented(options: options, selection: $selection)
        }
        .padding(.vertical, 4)
    }
}

/// A `Section` with a small uppercase section label in the theme's brown (same as `SectionHeader`).
struct GlassSection<Content: View>: View {
    let title: String
    private let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.sectionLabel)
        }
    }
}

// MARK: Coloured icon squircle (the Apple Settings row icon)

/// F-15: every row icon is drawn the same way, the accent on a sand squircle (the per-row colours of the Apple look made the
/// list screens loud and blue). `tint` is kept for the call sites only.
struct SquircleLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .frame(width: 29, height: 29)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// A Settings-style row label: white symbol on a coloured squircle
    func squircle(_ tint: Color) -> some View {
        labelStyle(SquircleLabelStyle(tint: tint))
    }
}

// MARK: Haptics (F-03)

/// Standard iOS feedback for the few significant buttons. Where the view disappears with the action (end of ride, delete)
/// the UIKit generator is used, which follows the same system "System Haptics" setting.
enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: Chip flow

/// Chips in a row that wrap onto the next line instead of running off the edge (big text sizes).
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}
