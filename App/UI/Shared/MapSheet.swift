import SwiftUI
import UIKit

/// UI_PLAN 1.6: a full-bleed map with a draggable sheet (peek / half / full) and a top bar.
/// B19 (owner, 13 Oct): the sheet docks ON the floating tab bar. Closed (peek), its foot sits on the bar with the same width and
/// corner radius and shows only the grab handle and a one-line `summary` ("19.0 km · 29 min · 99 → 53%"); dragging slides it up
/// out of the bar. The bar always stays in front (it is pinned while a map sheet is on screen, F-14) and nothing scrolls under it:
/// the sheet's content is cut at the bar's top edge. Without a bar (the ride summary cover) the sheet floats at the bottom the same
/// way. The sheet drags by its handle and summary (any time) and by its whole surface while it is not full; at full height the
/// content scrolls instead, so drag and scroll never fight.
/// Used by: ride detail, route card, the place map, and Home's "Where to?" (`DockedSheet`). Task sheets (Compare picker, Merge,
/// Trim, Replay, Share, check guide / note) stay standard iOS sheets (`glassPresentation`).
enum SheetDetent: Int, CaseIterable {
    case peek, half, full
}

/// Pure geometry of a docked sheet (B19), shared by `MapSheet` / `DockedSheet` and checked by u63.
struct SheetDock {
    /// height of the grab handle row
    static let handle: CGFloat = 22
    /// height of the one-line summary row
    static let summary: CGFloat = 34
    /// total height of the layout, the device's bottom safe area, whether the floating bar is there
    let total: CGFloat
    let bottomInset: CGFloat
    let hasBar: Bool

    /// distance from the screen bottom to the sheet's foot (= the bar's bottom edge, so the bar sits inside the sheet's foot)
    var bottom: CGFloat { bottomInset + FloatingTabBar.bottomGap }
    /// the part of the sheet the bar covers (nothing is drawn there but the sheet's own background)
    var barSpace: CGFloat { hasBar ? FloatingTabBar.barHeight : 0 }
    /// bottom corner radius: the bar's, so the two outlines run together
    var bottomRadius: CGFloat { FloatingTabBar.radius }

    func height(_ d: SheetDetent) -> CGFloat {
        let peek = Self.handle + Self.summary + barSpace + (hasBar ? 0 : 8)
        let room = total - bottom
        switch d {
        case .peek: return peek
        case .half: return max(peek + 120, room * 0.5)
        case .full: return max(peek + 160, room - 96)
        }
    }

    /// the visible content height above the bar at a sheet height
    func contentHeight(at h: CGFloat) -> CGFloat { max(0, h - barSpace) }

    /// the device's bottom safe area (home indicator), read from the window: the layout itself ignores the bottom safe area
    @MainActor static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
    }

    /// the detent nearest to where a drag would end
    func settle(from d: SheetDetent, predicted: CGFloat) -> SheetDetent {
        let target = height(d) - predicted
        return SheetDetent.allCases.min { abs(height($0) - target) < abs(height($1) - target) } ?? d
    }
}

struct MapSheet<MapContent: View, TopBar: View, Side: View, Sheet: View>: View {
    @State private var detent: SheetDetent
    private let summary: String
    private let map: MapContent
    private let topBar: TopBar
    private let side: Side
    private let sheet: Sheet

    init(initial: SheetDetent = .half,
         summary: String = "",
         @ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder side: () -> Side,
         @ViewBuilder sheet: () -> Sheet) {
        _detent = State(initialValue: initial)
        self.summary = summary
        self.map = map()
        self.topBar = topBar()
        self.side = side()
        self.sheet = sheet()
    }

    var body: some View {
        // B11: the drag state lives in `SheetLayer`; this body (with the map) is not re-evaluated while a finger moves.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                map
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.top, 4)
                    HStack {
                        Spacer(minLength: 0)
                        if detent != .full { side }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, 10)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                SheetLayer(detent: $detent, total: geo.size.height, bottomInset: max(geo.safeAreaInsets.bottom, SheetDock.windowBottomInset), summary: summary) { sheet }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// B19 without a map: the docked sheet over any screen (Home's "Where to?"). Same look and drag as `MapSheet`'s sheet.
struct DockedSheet<Sheet: View>: View {
    @Binding var detent: SheetDetent
    let summary: String
    private let sheet: Sheet

    init(detent: Binding<SheetDetent>, summary: String, @ViewBuilder sheet: () -> Sheet) {
        _detent = detent
        self.summary = summary
        self.sheet = sheet()
    }

    var body: some View {
        GeometryReader { geo in
            SheetLayer(detent: $detent, total: geo.size.height, bottomInset: max(geo.safeAreaInsets.bottom, SheetDock.windowBottomInset), summary: summary) { sheet }
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// The sheet itself. Its content is laid out once at the full height and only moved (offset) while it is dragged or settles, so
/// the content is not re-laid out every frame; the drag lives in a `GestureState` that resets by itself. The outline and a mask
/// follow the current height, so the content is cut at the bar's top edge (B19: nothing under the bar).
private struct SheetLayer<Content: View>: View {
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hasFloatingTabBar) private var hasBar
    @Binding var detent: SheetDetent
    let total: CGFloat
    let bottomInset: CGFloat
    let summary: String
    @GestureState private var drag: CGFloat = 0
    private let content: Content

    init(detent: Binding<SheetDetent>, total: CGFloat, bottomInset: CGFloat, summary: String, @ViewBuilder content: () -> Content) {
        _detent = detent
        self.total = total
        self.bottomInset = bottomInset
        self.summary = summary
        self.content = content()
    }

    private var dock: SheetDock { SheetDock(total: total, bottomInset: bottomInset, hasBar: hasBar) }

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    var body: some View {
        let d = dock
        let maxH = d.height(.full)
        let current = min(max(d.height(detent) - drag, d.height(.peek)), maxH)
        ZStack(alignment: .bottom) {
            outline(d, height: current)
            // the content at full height, moved down and cut off at the bar's top
            sheetContent(height: d.contentHeight(at: maxH))
                .offset(y: maxH - current)
                .frame(height: d.contentHeight(at: maxH), alignment: .top)
                .mask(alignment: .bottom) {
                    UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, topTrailingRadius: DS.Radius.hero, style: .continuous)
                        .frame(height: d.contentHeight(at: current))
                }
                .padding(.bottom, d.barSpace)
        }
        .frame(height: maxH, alignment: .bottom)
        .padding(.horizontal, DS.Space.gutter)
        .padding(.bottom, d.bottom)
        .animation(spring, value: detent)
        .onAppear { if hasBar { TabBarVisibility.shared.pin() } }
        .onDisappear { if hasBar { TabBarVisibility.shared.unpin() } }
    }

    /// the sheet's outline at its current height; its foot runs behind the bar
    private func outline(_ d: SheetDock, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, bottomLeadingRadius: d.bottomRadius,
                                           bottomTrailingRadius: d.bottomRadius, topTrailingRadius: DS.Radius.hero, style: .continuous)
        return shape
            .fill(sunlight ? Theme.row : Theme.background)   // white / #121212, so the sand / #1F1F1F tiles stand out
            .overlay { shape.strokeBorder(sunlight ? Color(.separator) : Theme.line, lineWidth: sunlight ? 1 : 0.5) }
            .frame(height: height)
            .shadow(color: .black.opacity(sunlight ? 0 : 0.12), radius: 12, y: -2)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { detent = dock.settle(from: detent, predicted: $0.predictedEndTranslation.height) }
    }

    private func sheetContent(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            handle
            summaryLine
            ScrollView {
                content
                    .padding(.horizontal, DS.Space.cardPad)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            .contentMargins(.bottom, 0, for: .scrollContent)
            .scrollDisabled(detent != .full)
            .scrollBounceBehavior(.basedOnSize)
            // while the sheet is not full, a drag anywhere on it moves the sheet
            .gesture(dragGesture, including: detent == .full ? .subviews : .all)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
    }

    private var summaryLine: some View {
        Text(summary)
            .font(.headline)
            .fontDesign(.rounded)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: SheetDock.summary, alignment: .leading)
            .padding(.horizontal, DS.Space.cardPad + 4)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { detent = detent == .peek ? .half : .peek }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to open or close the sheet")
    }

    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: SheetDock.handle)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture {
                detent = detent == .full ? .half : (detent == .half ? .full : .half)
            }
            .accessibilityElement()
            .accessibilityLabel("Sheet")
            .accessibilityValue(detent == .full ? "Full" : (detent == .half ? "Half" : "Small"))
            .accessibilityHint("Double tap to make the sheet bigger or smaller")
            .accessibilityAddTraits(.isButton)
    }
}

extension MapSheet where Side == EmptyView {
    init(initial: SheetDetent = .half,
         summary: String = "",
         @ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder sheet: () -> Sheet) {
        self.init(initial: initial, summary: summary, map: map, topBar: topBar, side: { EmptyView() }, sheet: sheet)
    }
}

// MARK: Glass top bar and vertical layer control

/// The capsule over the map: a leading round button, a title with a subtitle, trailing round buttons.
struct GlassTopBar<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let leading: Leading
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).fontDesign(.rounded).lineLimit(1).minimumScaleFactor(0.7)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassCard(radius: DS.Radius.hero, padding: 0)
    }
}

/// The prototype's vertical control on the right edge of the map (Speed / Wind / Hills).
struct GlassLayerControl<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(options[i].1)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onAccent : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 72, minHeight: DS.hit)
                        .background(on ? Theme.accent : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sunPanel(RoundedRectangle(cornerRadius: 16, style: .continuous), thin: true)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map layer")
    }
}

// MARK: Swipe back with the navigation bar hidden

/// A screen that hides the system navigation bar (the glass bar replaces it) would lose the edge swipe back.
/// This keeps it: the pop gesture is allowed whenever there is a screen to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
