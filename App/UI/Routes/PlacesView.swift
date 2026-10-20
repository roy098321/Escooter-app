import CorckieCore
import SwiftUI

/// M2-05 / F-06: Places (IA: Routes → Places, and Settings → Places). Every place the app learned, as its round quick-dial icon in
/// its colour (P6-5); tap one for the full map with the street name, Rename, the circle size, the colour and "I can charge here". The "+" adds a
/// place by hand (F-13). All text comes from CorckieCore (`PlaceListBuilder`); this view only draws it.
struct PlacesView: View {
    var preview: [PlaceMapItem]?

    @State private var items: [PlaceMapItem] = []
    @State private var icons: [String: PlaceIcon] = [:]

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
            // P6-5 (B42): the place's quick-dial icon in its own colour, the same round style as Home, instead of a map thumbnail
            PlaceIconView(icon: icons[place.id] ?? PlaceIcon.automatic(name: place.row.hasName ? place.row.title : nil), size: 52, selected: true,
                          colourId: place.colourId)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.row.title).font(.body).foregroundStyle(place.row.hasName ? Color.primary : Color.secondary)
                Text(place.row.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // B42: every card is the full row width
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        guard preview == nil else {
            icons = ["p1": .symbol("house"), "p2": .symbol("building.2")]   // ui-shots: made-up icons
            return
        }
        guard let db = AppModel.shared.displayDatabase else {
            items = []
            return
        }
        items = PlaceMapLoader.items(database: db)
        icons = QuickDialLoader.icons(db)
    }
}
