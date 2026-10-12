import SwiftUI

/// UI overhaul (UI_PLAN section 1): the shared tokens and small components every screen is built from.
/// Colours stay the system colours (C29); the glass is the material fallback (`sunPanel`), so sunlight mode
/// and Reduce Transparency keep turning it into a solid panel with a black edge (C30).
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

// MARK: Glass card

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
                if let tint { shape.fill(tint.opacity(sunlight ? 0.2 : 0.14)) }
            }
            .sunPanel(shape, thin: thin)
            .overlay {
                if !sunlight { shape.strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            }
    }
}

extension View {
    /// The card of the new look: frosted material, thin white edge, optional tint; solid with a black edge in sunlight.
    func glassCard(radius: CGFloat = DS.Radius.card, tint: Color? = nil, padding: CGFloat = DS.Space.cardPad, thin: Bool = false) -> some View {
        modifier(GlassCardStyle(radius: radius, tint: tint, padding: padding, thin: thin))
    }

    /// Sheet style: detents, drag indicator, frosted background, radius 28. (Every file that presents one still carries the version label.)
    func glassPresentation(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(DS.Radius.hero)
    }
}

// MARK: Stat tile

/// A squircle tile with a centred number and a small label (prototype 3 x 2 grid).
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color?
    var note: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .scaledFont(24, weight: .semibold, mono: true, relativeTo: .title2)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .glassCard(radius: DS.Radius.tile, tint: tint, padding: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.map { "\(label), \(value), \($0)" } ?? "\(label), \(value)")
    }
}

/// Adaptive grid of tiles: 3 columns at normal size, fewer at large Dynamic Type.
struct StatTileGrid<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var minTile: CGFloat = 100
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile), spacing: DS.Space.row)], spacing: DS.Space.row) {
            content
        }
    }
}

// MARK: Section header, info box, pill

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The tinted explanation box (accent 12 %).
struct InfoBox: View {
    let text: String
    var symbol: String?
    var tint: Color = .accentColor

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

struct Pill: View {
    let text: String
    var tint: Color = .accentColor
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(filled ? tint : tint.opacity(0.15), in: Capsule())
            .foregroundStyle(filled ? Color.white : tint)
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
                    Text(options[i].1)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Color(.systemBackground) : Color.clear, in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

// MARK: Glass list (Settings, Developer and the other list screens)

private struct GlassRowBackground: View {
    @Environment(\.sunlight) private var sunlight

    var body: some View {
        if sunlight {
            Color(.systemBackground)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

extension View {
    /// A standard `List` / `Form` on the map backdrop: no grey page, sentence-case section headers.
    func glassList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { MapBackdrop().ignoresSafeArea() }
            .textCase(nil)
    }

    /// Frosted rows for the content it is put on (a `Section`, or a few rows).
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

/// A `Section` with a sentence-case header (the system list upper-cases plain titles).
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
            Text(title).textCase(nil)
        }
    }
}
