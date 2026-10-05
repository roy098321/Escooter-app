import Charts
import CorckieCore
import MapKit
import SwiftUI

/// M2-04: the route card (CONCEPT: saved route view). Top to bottom: title and "based on N rides", the map with the usual path (other
/// variants dashed), six stats as ranges, the Today strip, variants, elevation both ways, the rides on this route. Sections with
/// nothing to show are left out (STATES S9). All text comes from CorckieCore (`RouteCardBuilder`); this view only draws it.
/// Later milestones add: Arrive by and there-and-back (M2-07 / M2-09), choice points and the fastest combination (M6), factors (M4).
struct RouteCardView: View {
    var routeId: String?
    var preview: RouteCardModel?

    @State private var model: RouteCardModel?
    @State private var missing = false
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var confirmRemove = false
    @State private var errorText: String?
    @State private var arriveInfo: (rides: [RouteRideStats], destination: String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let m = preview ?? model {
                content(m)
            } else if missing {
                ContentUnavailableView("Route not found", systemImage: "questionmark.circle",
                                       description: Text("This route is no longer stored."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle((preview ?? model)?.title ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { nameDraft = (preview ?? model)?.title ?? ""; showRename = true } label: { Label("Rename route", systemImage: "pencil") }
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove route", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Rename route", isPresented: $showRename) {
            TextField("Name", text: $nameDraft)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the names of the two places.")
        }
        .confirmationDialog("Remove this route?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove route", role: .destructive) { remove() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your rides stay in Rides. The same two trips will not be suggested again.")
        }
        .alert("Could not change the route", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: load)
        .screen("Route card")
    }

    // MARK: Layout

    private func content(_ m: RouteCardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(m.subtitle).font(.subheadline).foregroundStyle(.secondary)
                if !m.saved { suggestionCard }
                if !m.map.isEmpty { mapCard(m.map) }
                todayCard(m.today)
                if m.saved { arriveBy(m) }
                if let t = m.thereAndBack { thereAndBackCard(t) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(m.stats.enumerated()), id: \.offset) { _, s in tile(s) }
                }
                if !m.variants.isEmpty { variantsCard(m.variants) }
                if let e = m.elevation { elevationCard(e) }
                ridesCard(m)
            }
            .padding(16)
        }
    }

    @ViewBuilder private func arriveBy(_ m: RouteCardModel) -> some View {
        if preview != nil {
            ArriveByCard(routeId: nil, destination: "Work", rides: RoutesPreview.arriveByRides(), preview: true)
        } else if let info = arriveInfo {
            ArriveByCard(routeId: routeId, destination: info.destination, rides: info.rides)
        }
    }

    private func thereAndBackCard(_ t: ThereAndBackModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.headline).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(t.detail).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save as route?").font(.headline)
            Text("You have ridden this same trip more than once. Save it to keep your usual time and today's estimate in the Routes list.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Save route") { setSaved(true) }.buttonStyle(.borderedProminent)
                Button("Not a route") { setSaved(false) }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func mapCard(_ lines: [RouteMapLine]) -> some View {
        Map(initialPosition: Self.position(lines), interactionModes: [.pan, .zoom]) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                MapPolyline(coordinates: l.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(l.dashed ? Color.orange : Color.blue,
                            style: StrokeStyle(lineWidth: l.dashed ? 4 : 5, lineCap: .round, lineJoin: .round, dash: l.dashed ? [2, 8] : []))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if lines.count > 1 {
                Text("\(lines.count) variants")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private func todayCard(_ t: RouteTodayStrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.headline).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(t.filling ? Color.secondary : Color.primary)
            Text(t.detail).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tile(_ s: RouteStatRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label).font(.footnote).foregroundStyle(.secondary)
            Text(s.value)
                .font(.system(size: s.filling ? 17 : 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(s.filling ? Color.secondary : Color.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let note = s.note {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func variantsCard(_ rows: [RouteVariantRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Variants").font(.headline).padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, v in
                if i > 0 { Divider() }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name)
                        Text(v.isReference ? "Usual way" : "Other way").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(v.timeText).monospacedDigit()
                        if let b = v.batteryText { Text(b).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func elevationCard(_ e: RouteElevationModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Elevation").font(.headline)
            Text(e.thisWay).font(.subheadline).monospacedDigit()
            Text(e.otherWay).font(.subheadline).foregroundStyle(e.otherIsEstimate ? Color.secondary : Color.primary).monospacedDigit()
            Text("From the phone's barometer, so the numbers are approximate.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func ridesCard(_ m: RouteCardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rides on this route").font(.headline)
            if m.trendMin.count >= 2 {
                Chart(Array(m.trendMin.enumerated()), id: \.offset) { i, minutes in
                    LineMark(x: .value("Ride", i), y: .value("Minutes", minutes))
                    PointMark(x: .value("Ride", i), y: .value("Minutes", minutes))
                }
                .chartXAxis(.hidden)
                .chartYAxisLabel("min")
                .frame(height: 110)
            }
            ForEach(Array(m.rides.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider() }
                NavigationLink {
                    RideDetailView(rideId: r.rideId)
                } label: {
                    HStack {
                        Text(r.title)
                        Spacer()
                        Text("\(r.timeText) \u{00B7} \(r.batteryText)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if m.totalRides > m.rides.count {
                Text("\(m.totalRides) rides in all. The newest \(m.rides.count) are listed here; all of them are in Rides.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func position(_ lines: [RouteMapLine]) -> MapCameraPosition {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for l in lines {
            for p in l.points {
                minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
                minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
            }
        }
        guard minLat <= maxLat else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.3), longitudeDelta: max(0.004, (maxLon - minLon) * 1.3))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    // MARK: Data

    private func load() {
        guard preview == nil else { return }
        guard let id = routeId, let db = AppModel.shared.displayDatabase, let loaded = RouteCardLoader.card(routeId: id, database: db, battery: BatteryNowSource.current(database: db)) else {
            missing = true
            return
        }
        model = loaded
        if let input = RouteCardLoader.cardInput(routeId: id, database: db) {
            arriveInfo = (input.rides, WhereTo.label(toName: input.toName, title: loaded.title))
        }
        // a street name from the phone may arrive a moment later: ask again, then read again
        RouteNaming.start(routeId: id, database: db)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let again = RouteCardLoader.card(routeId: id, database: db, battery: BatteryNowSource.current(database: db)) { model = again }
        }
    }

    private func setSaved(_ save: Bool) {
        guard preview == nil, let id = routeId, let db = AppModel.shared.displayDatabase else { return }
        do {
            if save {
                try RouteService.save(routeId: id, database: db)
                model = RouteCardLoader.card(routeId: id, database: db, battery: BatteryNowSource.current(database: db))
            } else {
                try RouteService.dismiss(routeId: id, database: db)
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func rename() {
        guard preview == nil, let id = routeId, let db = AppModel.shared.displayDatabase else { return }
        do {
            try RouteService.rename(routeId: id, name: nameDraft, database: db)
            model = RouteCardLoader.card(routeId: id, database: db, battery: BatteryNowSource.current(database: db))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove() {
        guard preview == nil, let id = routeId, let db = AppModel.shared.displayDatabase else { return }
        do {
            try RouteService.remove(routeId: id, database: db)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
