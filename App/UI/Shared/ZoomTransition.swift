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
