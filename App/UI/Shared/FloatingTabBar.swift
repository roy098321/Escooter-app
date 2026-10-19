import Observation
import SwiftUI

/// F-14 (owner, 18 Oct): one flat capsule with five icons, no text (VoiceOver keeps the names), Home a normal icon in the middle
/// of the row (no raised disc), the selected tab a filled icon on a soft orange pill. It is drawn by `RootView` over the five tab
/// screens and never inside the live ride view (the ride cover has no tabs). Tapping the tab you are on goes back to its first screen.
///
/// On list screens it slides away when you scroll down and comes back when you scroll up (`TabBarVisibility`, fed by the shared
/// scroll hook in StiffBounce.swift). B28: screens with a bottom action (Add a place, the place screen) hide it for as long as they
/// are on screen (`hidesTabBar()`). Nothing pins it any more (B29: no docked sheets).
struct FloatingTabBar: View {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let symbol: String
    }

    static let items: [Item] = [
        Item(id: 0, title: "Routes", symbol: "point.topleft.down.to.point.bottomright.curvepath"),
        Item(id: 1, title: "Rides", symbol: "list.bullet.rectangle.portrait"),
        Item(id: 2, title: "Home", symbol: "house"),
        Item(id: 3, title: "Stats", symbol: "chart.bar"),
        Item(id: 4, title: "Scooter", symbol: "scooter")
    ]

    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    @Environment(\.sunlight) private var sunlight

    /// the capsule's height
    static let barHeight: CGFloat = 60
    /// the gap between the capsule and the bottom of the safe area (home indicator)
    static let bottomGap: CGFloat = 8
    /// corner radius of the capsule; docked sheets use the same at their bottom corners (B19)
    static let radius: CGFloat = barHeight / 2
    /// What the bar covers at the bottom of a tab (bar + the gap below + a little air): scroll content gets this as a bottom
    /// margin (B20 / B23), so the last item scrolls fully above the bar. No raised Home disc any more (F-14).
    static let clearance: CGFloat = barHeight + bottomGap + 12
    private static let pillWidth: CGFloat = 54
    private static let pillHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items) { cell($0) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .background {
            Capsule().fill(Theme.bar)
                .shadow(color: .black.opacity(sunlight ? 0 : 0.10), radius: 10, y: 2)
        }
        .overlay { Capsule().strokeBorder(sunlight ? Color(.separator) : Theme.line, lineWidth: sunlight ? 1 : 0.5) }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.bottom, Self.bottomGap)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }

    private func cell(_ item: Item) -> some View {
        let on = selection == item.id
        return Button {
            if on { onReselect(item.id) } else { selection = item.id }
        } label: {
            Image(systemName: item.symbol)
                .symbolVariant(on ? .fill : .none)
                .font(.system(size: 20, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.onAccent : Color.secondary)
                .frame(width: Self.pillWidth, height: Self.pillHeight)
                .background { if on { Capsule().fill(Theme.accent) } }
                .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// F-14: whether the floating bar is shown. List screens report their scrolling (`scrolled`); a screen with a bottom action holds the bar
/// away (`hold` / `release`, B28), and switching tabs always brings a scroll-hidden bar back. The scroll decision is `TabBarHideRule`
/// (pure, checked by u62).
@MainActor
@Observable
final class TabBarVisibility {
    static let shared = TabBarVisibility()
    private(set) var scrollHidden = false
    private(set) var holds = 0
    private var rule = TabBarHideRule()
    private init() {}

    /// the bar is away: scrolled down, or a screen with a bottom action holds it
    var hidden: Bool { scrollHidden || holds > 0 }

    /// A scroll view moved while the finger or its momentum drives it: y = content offset, top / bottom = its resting ends
    func scrolled(y: CGFloat, top: CGFloat, bottom: CGFloat) {
        let next = rule.step(y: Double(y), top: Double(top), bottom: Double(bottom))
        if next != scrollHidden { scrollHidden = next }
    }

    func show() {
        rule.reset()
        if scrollHidden { scrollHidden = false }
    }

    /// a screen with a bottom action is on screen: the bar stays away until `release`
    func hold() { holds += 1 }

    func release() { holds = max(0, holds - 1) }
}

extension View {
    /// B28: hides the floating tab bar while this screen is shown (Add a place, the place screen: their actions must not sit under it)
    func hidesTabBar() -> some View {
        modifier(HidesTabBar())
    }
}

private struct HidesTabBar: ViewModifier {
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !holding else { return }
                holding = true
                TabBarVisibility.shared.hold()
            }
            .onDisappear {
                guard holding else { return }
                holding = false
                TabBarVisibility.shared.release()
            }
    }
}

/// The hide-on-scroll rule (F-14): hide after scrolling down 24 pt in one go, show again after scrolling up 12 pt, always shown
/// near the top (first 40 pt) and never changed by the rubber band past either end.
struct TabBarHideRule {
    static let hideAfter = 24.0
    static let showAfter = 12.0
    static let topZone = 40.0

    private(set) var hidden = false
    private var anchor: Double?
    private var lastY: Double?

    mutating func reset() {
        hidden = false
        anchor = nil
        lastY = nil
    }

    /// Feeds one content offset; returns whether the bar should be hidden now
    mutating func step(y: Double, top: Double, bottom: Double) -> Bool {
        if y < top + Self.topZone {
            hidden = false
            anchor = y
            lastY = y
            return hidden
        }
        if bottom > top, y > bottom { return hidden }    // the bounce past the end
        guard let last = lastY else {
            lastY = y
            anchor = y
            return hidden
        }
        // a change of direction starts a new run
        if let a = anchor, (y - last) * (last - a) < 0 { anchor = last }
        lastY = y
        let run = y - (anchor ?? y)
        if !hidden, run >= Self.hideAfter { hidden = true; anchor = y }
        if hidden, run <= -Self.showAfter { hidden = false; anchor = y }
        return hidden
    }
}

extension View {
    /// Puts the floating tab bar over this view (the five tabs in `RootView`, and the ui-shots that show it). It slides away on
    /// scroll (unless a screen holds it away) and honours Reduce Motion with a fade instead of the slide.
    func floatingTabBar(selection: Binding<Int>, onReselect: @escaping (Int) -> Void = { _ in }) -> some View {
        modifier(FloatingTabBarHost(selection: selection, onReselect: onReselect))
    }
}

private struct FloatingTabBarHost: ViewModifier {
    @Binding var selection: Int
    let onReselect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let visibility = TabBarVisibility.shared

    func body(content: Content) -> some View {
        content
            .environment(\.hasFloatingTabBar, true)
            .overlay(alignment: .bottom) {
                FloatingTabBar(selection: $selection, onReselect: onReselect)
                    .offset(y: visibility.hidden && !reduceMotion ? FloatingTabBar.barHeight + 60 : 0)
                    .opacity(visibility.hidden && reduceMotion ? 0 : 1)
                    .allowsHitTesting(!visibility.hidden)
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85), value: visibility.hidden)
            }
            .onChange(of: selection) { _, _ in visibility.show() }
    }
}

private struct HasFloatingTabBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true under the floating tab bar (scroll areas leave room for it); false in the ride cover and the sheets
    var hasFloatingTabBar: Bool {
        get { self[HasFloatingTabBarKey.self] }
        set { self[HasFloatingTabBarKey.self] = newValue }
    }
}
