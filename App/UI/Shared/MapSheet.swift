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
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detent: SheetDetent
    @State private var drag: CGFloat = 0
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

    private func height(_ d: SheetDetent, _ total: CGFloat) -> CGFloat {
        switch d {
        case .peek: return 132
        case .half: return max(220, total * 0.5)
        case .full: return max(260, total - 96)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let minH = height(.peek, total)
            let maxH = height(.full, total)
            let current = min(max(height(detent, total) - drag, minH), maxH)
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
                sheetView(total: total, height: current)
            }
        }
    }

    private func settle(_ translation: CGFloat, predicted: CGFloat, total: CGFloat) {
        let start = height(detent, total)
        let target = start - predicted
        var best = detent
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for d in SheetDetent.allCases {
            let dist = abs(height(d, total) - target)
            if dist < bestDistance { bestDistance = dist; best = d }
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
            detent = best
            drag = 0
        }
    }

    private func dragGesture(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation.height }
            .onEnded { settle($0.translation.height, predicted: $0.predictedEndTranslation.height, total: total) }
    }

    private func sheetView(total: CGFloat, height h: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, topTrailingRadius: DS.Radius.hero, style: .continuous)
        return VStack(spacing: 0) {
            handle(total: total)
            ScrollView {
                sheet
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.bottom, 110)
            }
            .scrollDisabled(detent != .full)
            .scrollBounceBehavior(.basedOnSize)
            // while the sheet is not full, a drag anywhere on it moves the sheet
            .gesture(dragGesture(total: total), including: detent == .full ? .subviews : .all)
        }
        .frame(maxWidth: .infinity)
        .frame(height: h, alignment: .top)
        .background {
            if sunlight {
                shape.fill(Color(.systemBackground))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(alignment: .top) {
            shape.strokeBorder(sunlight ? Color.primary : Color.white.opacity(0.35), lineWidth: sunlight ? 2 : 1)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(sunlight ? 0 : 0.12), radius: 12, y: -2)
        .ignoresSafeArea(edges: .bottom)
    }

    private func handle(total: CGFloat) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .gesture(dragGesture(total: total))
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
                    detent = detent == .full ? .half : (detent == .half ? .full : .half)
                }
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
