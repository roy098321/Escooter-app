import CorckieCore
import SwiftUI

/// Note 11 (owner 24 Oct, A): the ride review screen. The map fills the screen; the top bar, layer row and legend float over it and stay
/// visible; the numbers sit on a card that is dragged like Apple Maps and snaps to full / default / one line / hidden (only a lip at the
/// bottom, tap it to raise the card). Heights and snapping are in Core (`RideCardLayout`, unit tested).
/// Partly reverses B29 ("nothing to drag") for this one screen (dilemma D-PR-07); the route card and the place map keep `MapScreen`.
struct RideCardScreen<MapContent: View, TopBar: View, Side: View, Line: View, Content: View>: View {
    @Binding var detent: CardDetent
    private let map: MapContent
    private let topBar: TopBar
    private let side: Side
    private let line: Line
    private let content: Content

    @Environment(\.hasFloatingTabBar) private var hasBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var controlsBottom: CGFloat = 170

    init(detent: Binding<CardDetent>,
         @ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder side: () -> Side,
         @ViewBuilder line: () -> Line,
         @ViewBuilder content: () -> Content) {
        _detent = detent
        self.map = map()
        self.topBar = topBar()
        self.side = side()
        self.line = line()
        self.content = content()
    }

    private var bottomReserve: CGFloat { hasBar ? FloatingTabBar.clearance : 0 }

    var body: some View {
        GeometryReader { geo in
            let h = Double(geo.size.height)
            let tops = Dictionary(uniqueKeysWithValues: CardDetent.allCases.map { d in
                (d, CGFloat(RideCardLayout.top(d, height: h, topInset: Double(geo.safeAreaInsets.top),
                                               controlsBottom: Double(controlsBottom), bottomReserve: Double(bottomReserve))))
            })
            let top = tops[detent] ?? 0
            let fullTop = tops[.full] ?? 0
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()
                map.ignoresSafeArea()
                controls
                card(height: geo.size.height - fullTop + geo.safeAreaInsets.bottom, extraBottom: top - fullTop,
                     drag: dragGesture(tops: tops, top: top))
                    .offset(y: max(fullTop, top + drag))
                if detent == .hidden { lip.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, bottomReserve + 4) }
            }
        }
    }

    // MARK: Parts

    private var controls: some View {
        VStack(spacing: 10) {
            topBar
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, 4)
            side
                .padding(.horizontal, DS.Space.gutter)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: ControlsBottomKey.self, value: g.frame(in: .named("rideCard")).maxY)
        })
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "rideCard")
        .onPreferenceChange(ControlsBottomKey.self) { v in
            if v > 0, abs(v - controlsBottom) > 1 { controlsBottom = v }
        }
    }

    /// The drag lives on the header (grabber + the one line) only, so the numbers below scroll normally
    private func card(height: CGFloat, extraBottom: CGFloat, drag: some Gesture) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, topTrailingRadius: DS.Radius.hero, style: .continuous)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                grabber
                if detent == .line {
                    line
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { set(.standard) }
                }
            }
            .contentShape(Rectangle())
            .gesture(drag)
            ScrollView {
                content
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
            }
            .contentMargins(.bottom, extraBottom + bottomReserve + 12, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .opacity(detent == .line || detent == .hidden ? 0 : 1)
            .allowsHitTesting(detent == .standard || detent == .full)
        }
        .frame(height: max(0, height), alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Theme.background, in: shape)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
    }

    /// The handle: drag it, or tap it to go one height up (full goes back to the default)
    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
            .onTapGesture { set(detent == .full ? .standard : detent.taller) }
            .accessibilityElement()
            .accessibilityLabel("Ride card")
            .accessibilityValue(Self.spoken(detent))
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(detent.taller)
                case .decrement: set(detent.shorter)
                @unknown default: break
                }
            }
    }

    /// Hidden: a small lip at the bottom; a tap (or a drag up) raises the card
    private var lip: some View {
        Button { set(.standard) } label: {
            Image(systemName: "chevron.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: RideCardLayout.lipHeight)
                .background(Theme.background, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the ride card")
        .gesture(DragGesture(minimumDistance: 8).onEnded { v in if v.translation.height < -20 { set(.standard) } })
    }

    // MARK: Drag

    private func dragGesture(tops: [CardDetent: CGFloat], top: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in drag = v.translation.height }
            .onEnded { v in
                let predicted = Double(top + v.predictedEndTranslation.height)
                let next = RideCardLayout.snap(predictedTop: predicted, tops: tops.mapValues { Double($0) })
                set(next)
            }
    }

    private func set(_ d: CardDetent) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)) {
            detent = d
            drag = 0
        }
        Haptics.tick()
    }

    static func spoken(_ d: CardDetent) -> String {
        switch d {
        case .full: return "Full height"
        case .standard: return "Default height"
        case .line: return "One line"
        case .hidden: return "Hidden"
        }
    }
}

private struct ControlsBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
