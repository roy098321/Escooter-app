import SwiftUI

// N7-3 (batch 7): a card grows into its detail screen and a swipe down shrinks it back into the same card (iOS 18
// `.navigationTransition(.zoom)` + `.matchedTransitionSource`). iOS 17 keeps the slide; with Reduce Motion the system cross-fades.
// Used by Rides → ride, Routes → route, Places → place map, Stats cards → their detail.

extension View {
    /// the card that grows (iOS 18; nothing on iOS 17)
    @ViewBuilder func zoomSource(_ id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: space) { $0.clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)) }
        } else {
            self
        }
    }

    /// the screen it grows into (iOS 18; the slide on iOS 17)
    @ViewBuilder func zoomDestination(_ id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: space))
        } else {
            self
        }
    }
}

// N7-11 (batch 7): the live tiles fly into their summary spots at ride end (ride time → Time, battery → Battery, speed → Avg speed).
// RideCover gives both screens one namespace; each pair shares an id. Without it (previews, the ride page from the list) nothing moves.
private struct RideMorphKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var rideMorph: Namespace.ID? {
        get { self[RideMorphKey.self] }
        set { self[RideMorphKey.self] = newValue }
    }
}

private struct RideMorphTile: ViewModifier {
    let id: String
    @Environment(\.rideMorph) private var space

    func body(content: Content) -> some View {
        if let space { content.matchedGeometryEffect(id: id, in: space, properties: .frame) } else { content }
    }
}

extension View {
    /// N7-11: this tile flies to (or from) its partner on the other ride screen
    func rideMorph(_ id: String) -> some View { modifier(RideMorphTile(id: id)) }
}

