import CorckieCore
import SwiftUI

/// M2-05 / F-06: Places (IA: Routes → Places, and Settings → Places). Every place the app learned, as its round quick-dial icon in
/// its colour (P6-5); tap one for the full map with the street name, Rename, the circle size, the colour and "I can charge here". The "+" adds a
/// place by hand (F-13). All text comes from CorckieCore (`PlaceListBuilder`); this view only draws it.
/// Places hold to drag (owner 21 Oct): long-press a card and drag it to reorder (the card lifts with a haptic, a light tick per slot, a light
/// haptic on drop; the order is saved, `PlaceOrder`); hold and let go without moving → the menu Rename · Colour · Icon · Show on Home.
/// B51: the › sits inside the card (the cards are full width).
struct PlacesView: View {
    var preview: [PlaceMapItem]?

    @State private var items: [PlaceMapItem] = []
    @State private var icons: [String: PlaceIcon] = [:]
    @State private var pins: [String: Int] = [:]
    /// the place whose screen is open (a tap, or Icon in the menu)
    @State private var opened: String?
    @State private var renaming: PlaceMapItem?
    @State private var nameDraft = ""
    @State private var replacingFor: String?
    @State private var dropTick = 0
    @State private var errorText: String?

    private var shown: [PlaceMapItem] { preview ?? items }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "mappin.slash",
                                       description: Text("Places appear when you ride the same trip twice, or add one with the + above."))
            } else {
                List {
                    ForEach(shown, id: \.id) { place in
                        Button { opened = place.id } label: { row(place) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(place) }
                            .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in move(from, to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .sensoryFeedback(.impact(weight: .light), trigger: dropTick)
            }
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { id in
            PlaceMapView(placeId: id, preview: preview?.first { $0.id == id })
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaceAddView() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a place")
            }
        }
        .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let p = renaming { rename(p, to: nameDraft) } }
        }
        .confirmationDialog("Home has 3 places. Replace which?", isPresented: Binding(get: { replacingFor != nil }, set: { if !$0 { replacingFor = nil } }),
                            titleVisibility: .visible) {
            if let new = replacingFor {
                ForEach(shown.filter { pins[$0.id] != nil }, id: \.id) { old in
                    Button(old.row.title) { writePins(QuickDialSlot.replace(old.id, with: new, in: pins)) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could not save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
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
            // B51: the chevron inside the card
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // B42: every card is the full row width
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the place. Touch and hold for Rename, Colour, Icon and Show on Home, or to drag it.")
    }

    /// Hold and let go without moving: Rename · Colour · Icon · Show on Home
    @ViewBuilder private func menu(_ place: PlaceMapItem) -> some View {
        Button { nameDraft = place.row.hasName ? place.row.title : ""; renaming = place } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            ForEach(PlaceColours.all, id: \.id) { c in
                Button { setColour(place, c.id) } label: {
                    if c.id == place.colourId { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
        } label: { Label("Colour", systemImage: "paintpalette") }
        Button { opened = place.id } label: { Label("Icon", systemImage: "circle.grid.2x2") }
        if place.row.hasName {
            Button { toggleHome(place) } label: {
                Label(pins[place.id] != nil ? "Remove from Home" : "Show on Home", systemImage: pins[place.id] != nil ? "pin.slash" : "pin")
            }
        }
    }

    // MARK: Reorder

    private func move(_ from: IndexSet, _ to: Int) {
        guard preview == nil else { return }
        let next = PlaceOrder.moved(items.map(\.id), from: from, to: to)
        items = next.compactMap { id in items.first { $0.id == id } }
        dropTick += 1
        guard let db = AppModel.shared.displayDatabase else { return }
        do { try RideQueries(db).setSetting(key: PlaceOrder.settingKey, json: PlaceOrder.json(next)) } catch { errorText = error.localizedDescription }
    }

    // MARK: Menu actions

    private func rename(_ place: PlaceMapItem, to name: String) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try PlaceService.rename(placeId: place.id, name: trimmed.isEmpty ? nil : trimmed, database: db) } catch { errorText = error.localizedDescription }
        reload()
    }

    private func setColour(_ place: PlaceMapItem, _ id: String) {
        Haptics.tick()
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        do { try PlaceColourStore.write(placeId: place.id, colourId: id, database: db) } catch { errorText = error.localizedDescription }
        reload()
    }

    private func toggleHome(_ place: PlaceMapItem) {
        Haptics.tick()
        if pins[place.id] != nil { return writePins(QuickDialSlot.unpin(place.id, in: pins)) }
        switch QuickDialSlot.pin(place.id, in: pins) {
        case .pinned(let next): writePins(next)
        case .needsReplace: replacingFor = place.id
        }
    }

    private func writePins(_ next: [String: Int]) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        do { try QuickDialLoader.writePins(next, database: db) } catch { errorText = error.localizedDescription }
        reload()
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
        let all = PlaceMapLoader.items(database: db)
        let saved = PlaceOrder.parse(try? RideQueries(db).setting(key: PlaceOrder.settingKey))
        items = PlaceOrder.apply(all.map(\.id), saved: saved).compactMap { id in all.first { $0.id == id } }
        icons = QuickDialLoader.icons(db)
        pins = QuickDialLoader.pins(db)
    }
}
