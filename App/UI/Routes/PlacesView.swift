import CorckieCore
import SwiftUI

/// M2-05: Places (IA: Routes → Places, and Settings → Places). Every place the app learned: rename it, pick the size of its circle
/// (automatic = 5% of the trip, T60) and say "I can charge here" (M27: a route to a place you can charge at only has to fit one way).
/// All text comes from CorckieCore (`PlaceListBuilder`); this view only draws it and writes the change.
struct PlacesView: View {
    var preview: [PlaceRowModel]?

    @State private var rows: [PlaceRowModel] = []
    @State private var renaming: PlaceRowModel?
    @State private var nameDraft = ""
    @State private var errorText: String?

    private var shown: [PlaceRowModel] { preview ?? rows }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "mappin.slash",
                                       description: Text("Places appear when you ride the same trip twice."))
            } else {
                List {
                    ForEach(shown, id: \.id) { place in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.title).font(.body).foregroundStyle(place.hasName ? Color.primary : Color.secondary)
                                    Text(place.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Rename") {
                                    nameDraft = place.hasName ? place.title : ""
                                    renaming = place
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Toggle("I can charge here", isOn: Binding(get: { place.canCharge },
                                                                      set: { setCharge(place, $0) }))
                            Picker("Circle", selection: Binding(get: { place.radiusM ?? 0 }, set: { setRadius(place, $0) })) {
                                Text("Automatic").tag(0.0)
                                ForEach(PlaceListBuilder.radiusChoices, id: \.self) { r in
                                    Text("\(Int(r)) m").tag(r)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to remove the name.")
        }
        .alert("Could not change the place", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: reload)
        .screen("Places")
    }

    private func reload() {
        guard preview == nil else { return }
        guard let db = AppModel.shared.displayDatabase else {
            rows = []
            return
        }
        rows = RouteCardLoader.places(database: db)
    }

    private func change(_ action: (AppDatabase) throws -> Void) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        do {
            try action(db)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveName() {
        guard let place = renaming else { return }
        let draft = nameDraft
        renaming = nil
        change { try PlaceService.rename(placeId: place.id, name: draft, database: $0) }
    }

    private func setCharge(_ place: PlaceRowModel, _ on: Bool) {
        change { try PlaceService.setCanCharge(placeId: place.id, canCharge: on, database: $0) }
    }

    private func setRadius(_ place: PlaceRowModel, _ metres: Double) {
        change { try PlaceService.setRadius(placeId: place.id, radiusM: metres > 0 ? metres : nil, database: $0) }
    }
}
