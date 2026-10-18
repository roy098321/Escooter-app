import CorckieCore
import SwiftUI

/// M2-05 / F-06: Places (IA: Routes → Places, and Settings → Places). Every place the app learned, on a small map with its circle in
/// its colour; tap one for the full map with the street name, Rename, the circle size, the colour and "I can charge here". The "+" adds a
/// place by hand (F-13). All text comes from CorckieCore (`PlaceListBuilder`); this view only draws it.
struct PlacesView: View {
    var preview: [PlaceMapItem]?

    @State private var items: [PlaceMapItem] = []

    private var shown: [PlaceMapItem] { preview ?? items }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "mappin.slash",
                                       description: Text("Places appear when you ride the same trip twice, or add one with the + above."))
            } else {
                List {
                    ForEach(shown, id: \.id) { place in
                        NavigationLink {
                            PlaceMapView(placeId: place.id, preview: preview != nil ? place : nil)
                        } label: {
                            row(place)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaceAddView() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a place")
            }
        }
        .onAppear(perform: reload)
        .screen("Places")
    }

    private func row(_ place: PlaceMapItem) -> some View {
        HStack(spacing: 12) {
            PlaceThumb(item: place)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(PlaceColourStore.color(place.colourId)).frame(width: 10, height: 10).accessibilityHidden(true)
                    Text(place.row.title).font(.body).foregroundStyle(place.row.hasName ? Color.primary : Color.secondary)
                }
                Text(place.row.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        guard preview == nil else { return }
        guard let db = AppModel.shared.displayDatabase else {
            items = []
            return
        }
        items = PlaceMapLoader.items(database: db)
    }
}
