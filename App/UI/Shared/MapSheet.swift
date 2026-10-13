import SwiftUI
import UIKit

/// UI_PLAN 1.6: a full-bleed map with a draggable glass sheet (peek / half / full) and a glass top bar.
/// UI layout only. The sheet drags by its handle (any time) and by its whole surface while it is not full;
/// at full height the content scrolls instead, so drag and scroll never fight. Fallback if this ever misbehaves:
/// the map-header layout the Rides detail had before (map above a scrolling stack of glass cards).
enum SheetDetent: Int, CaseIterable {
    case peek, half, full
}

struct MapSheet<MapContent: View, TopBar: View, Side: View, Sheet: View>: View {
    @State private var detent: SheetDetent
    private let map: MapContent
    private let topBar: TopBar
    private let side: Side
    private let sheet: Sheet

    init(initial: SheetDetent = .half,
         @ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder side: () -> Side,
         @ViewBuilder sheet: () -> Sheet) {
        _detent = State(initialValue: initial)
        self.map = map()
        self.topBar = topBar()
        self.side = side()
        self.sheet = sheet()
    }

    var body: some View {
        // B18: the layout runs under the home indicator and the floating tab bar, so the sheet reaches the very bottom.
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
                SheetLayer(detent: $detent, total: geo.size.height, bottomInset: geo.safeAreaInsets.bottom) { sheet }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// The sheet itself. It is laid out once at its full height and only moved (offset) while it is dragged or settles, so the
/// content is not re-laid out every frame; the drag lives in a `GestureState` that resets by itself.
private struct SheetLayer<Content: View>: View {
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var detent: SheetDetent
    let total: CGFloat
    let bottomInset: CGFloat
    @GestureState private var drag: CGFloat = 0
    private let content: Content

    init(detent: Binding<SheetDetent>, total: CGFloat, bottomInset: CGFloat, @ViewBuilder content: () -> Content) {
        _detent = detent
        self.total = total
        self.bottomInset = bottomInset
        self.content = content()
    }

    /// What the tab bar takes at the bottom (bar 64 + 8 + 24 for the disc), or the home indicator alone without a bar.
    private var cover: CGFloat { max(bottomInset, 34) }

    private func height(_ d: SheetDetent) -> CGFloat {
        switch d {
        case .peek: return max(120, cover + 50)
        case .half: return max(height(.peek) + 90, total * 0.5)
        case .full: return max(260, total - 96)
        }
    }

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    var body: some View {
        let maxH = height(.full)
        let current = min(max(height(detent) - drag, height(.peek)), maxH)
        sheetView(maxHeight: maxH)
            .offset(y: maxH - current)
            .animation(spring, value: detent)
    }

    private func settle(predicted: CGFloat) {
        let target = height(detent) - predicted
        var best = detent
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for d in SheetDetent.allCases {
            let dist = abs(height(d) - target)
            if dist < bestDistance { bestDistance = dist; best = d }
        }
        detent = best
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { settle(predicted: $0.predictedEndTranslation.height) }
    }

    private func sheetView(maxHeight: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, topTrailingRadius: DS.Radius.hero, style: .continuous)
        return VStack(spacing: 0) {
            handle
            ScrollView {
                content
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.bottom, cover + 90)
            }
            .scrollDisabled(detent != .full)
            .scrollBounceBehavior(.basedOnSize)
            // while the sheet is not full, a drag anywhere on it moves the sheet
            .gesture(dragGesture, including: detent == .full ? .subviews : .all)
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight, alignment: .top)
        .background {
            if sunlight {
                shape.fill(Color(.systemBackground))
            } else {
                shape.fill(.thinMaterial)
            }
        }
        .overlay(alignment: .top) {
            shape.strokeBorder(sunlight ? Color(.separator) : Color.white.opacity(0.35), lineWidth: sunlight ? 0.5 : 1)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(sunlight ? 0 : 0.12), radius: 12, y: -2)
        .ignoresSafeArea(edges: .bottom)
    }

    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 22)
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
         @ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder sheet: () -> Sheet) {
        self.init(initial: initial, map: map, topBar: topBar, side: { EmptyView() }, sheet: sheet)
    }
}

// MARK: Glass top bar and vertical layer control

/// The glass capsule over the map: a leading round button, a title with a subtitle, trailing round buttons.
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
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
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
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 72, minHeight: DS.hit)
                        .background(on ? Color.accentColor : Color.clear)
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
