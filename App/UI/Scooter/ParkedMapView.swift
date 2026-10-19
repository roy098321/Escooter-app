import CorckieCore
import MapKit
import SwiftUI

/// V17: where the scooter was last parked, on a map (opened from the "Parked · Work · 2 h ago" row on the Scooter tab). The spot is
/// the end point of the last ride; the top bar says how long ago, and one button hands the spot to Apple Maps (walking directions).
struct ParkedMapView: View {
    let spot: ParkedSpot
    let nowMs: Int64
    @Environment(\.dismiss) private var dismiss

    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon) }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700)),
            interactionModes: [.pan, .zoom]) {
            Marker("Scooter", systemImage: "scooter", coordinate: coordinate).tint(Theme.accent)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            GlassTopBar(title: ParkedText.line(spot, nowMs: nowMs)) {
                GlassIconButton(symbol: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                GlassIconButton(symbol: "figure.walk", label: "Walking directions in Maps") { openInMaps() }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 4)
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .accessibilityLabel("Map of where the scooter is parked")
        .screen("Parked")
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = "Scooter"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
