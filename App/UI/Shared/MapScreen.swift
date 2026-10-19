import CorckieCore
import SwiftUI
import UIKit

/// B29 (owner, 19 Oct): a map screen is a map of FIXED height on top and a normal scroll view below. No draggable sheet, no detents
/// (the docked sheets of B19 are retired); the glass top bar and the layer control float over the map, the numbers scroll below it.
/// The floating tab bar stays like on every other screen (it slides away on scroll); nothing pins it.
/// Used by: ride detail, route card, the place map. Task sheets (Compare picker, Merge, Trim, Replay, Share, check guide / note) and
/// Home's "Where to?" are standard iOS sheets (`glassPresentation`).
struct MapScreen<MapContent: View, TopBar: View, Side: View, Content: View>: View {
    @Environment(\.hasFloatingTabBar) private var hasBar
    private let map: MapContent
    private let topBar: TopBar
    private let side: Side
    private let content: Content

    init(@ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder side: () -> Side,
         @ViewBuilder content: () -> Content) {
        self.map = map()
        self.topBar = topBar()
        self.side = side()
        self.content = content()
    }

    /// how far the scroll area reaches up over the foot of the map (rounded corners)
    private let overlap: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let inset = geo.safeAreaInsets.top
            let mapHeight = CGFloat(MapScreenLayout.mapHeight(screenHeight: Double(geo.size.height + inset)))
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()
                map
                    .frame(height: mapHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                VStack(spacing: 0) {
                    controls
                        .frame(height: max(0, mapHeight - inset - overlap), alignment: .top)
                    scroller
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            topBar
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, 4)
            HStack {
                Spacer(minLength: 0)
                side
            }
            .padding(.horizontal, DS.Space.gutter)
            Spacer(minLength: 0)
        }
    }

    private var scroller: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.hero, topTrailingRadius: DS.Radius.hero, style: .continuous)
        return ScrollView {
            content
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .contentMargins(.bottom, hasBar ? FloatingTabBar.clearance : 12, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .stiffBounce()
        .background(Theme.background, in: shape)
        .clipShape(shape)
    }
}

extension MapScreen where Side == EmptyView {
    init(@ViewBuilder map: () -> MapContent,
         @ViewBuilder topBar: () -> TopBar,
         @ViewBuilder content: () -> Content) {
        self.init(map: map, topBar: topBar, side: { EmptyView() }, content: content)
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
