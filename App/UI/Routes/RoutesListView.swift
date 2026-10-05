import CorckieCore
import SwiftUI

/// M2-04 / M2-05: the Routes tab (IA: Routes tab). Saved routes with their rides and usual ranges, then "Suggested routes" (shown
/// only when there are any), then Places. A saved route the battery cannot reach is greyed with the reason (M27, G2); "One way only"
/// and "Tight" are amber chips; a greyed row can still be opened. Empty: pattern E. All text is made in CorckieCore
/// (`RouteListBuilder`, `RouteFit`).
struct RoutesListView: View {
    var preview: RouteListModel?

    @State private var model = RouteListModel(saved: [], suggested: [])
    @State private var placeCount = 0
    @State private var errorText: String?

    private var shown: RouteListModel { preview ?? model }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Routes")
                .screen("Routes")
        }
        .onAppear(perform: reload)
        .onChange(of: ScreenSimulator.shared.active) { _, _ in reload() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reload() }
        .alert("Could not change the route", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        let m = shown
        if m.isEmpty {
            ContentUnavailableView("No routes yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text("Ride the same trip twice and you'll be asked to save it."))
        } else {
            List {
                if !m.saved.isEmpty {
                    Section {
                        ForEach(m.saved, id: \.routeId) { row($0) }
                    } header: {
                        Text("Routes")
                    } footer: {
                        if m.saved.contains(where: { $0.fit.status != .noData }) {
                            Text("Greyed routes need more battery than you have, with a safety margin. They can still be opened.")
                        }
                    }
                }
                if !m.suggested.isEmpty {
                    Section {
                        ForEach(m.suggested, id: \.routeId) { row($0) }
                    } header: {
                        Text("Suggested routes")
                    } footer: {
                        Text("Trips you rode more than once. Swipe right to save one, left for Not a route, or open it first.")
                    }
                }
                if placeCount > 0 || preview != nil {
                    Section {
                        NavigationLink {
                            PlacesView()
                        } label: {
                            Label("Places", systemImage: "mappin.and.ellipse")
                        }
                    }
                }
            }
        }
    }

    private func row(_ r: RouteListRow) -> some View {
        NavigationLink {
            RouteCardView(routeId: r.routeId)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(r.title).font(.body)
                    if let chip = r.fit.chip { chipView(chip, greyed: r.fit.greyed) }
                }
                Text(r.summary).font(.footnote).foregroundStyle(.secondary)
                if let detail = r.fit.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .opacity(r.fit.greyed ? 0.55 : 1)
        }
        .swipeActions(edge: .leading) {
            if r.state == .suggested {
                Button("Save") { decide(r.routeId, save: true) }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if r.state == .suggested {
                Button("Not a route", role: .destructive) { decide(r.routeId, save: false) }
            }
        }
    }

    private func chipView(_ text: String, greyed: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(greyed ? Color.secondary : Color.orange)
            .background((greyed ? Color.gray : Color.orange).opacity(0.18), in: Capsule())
    }

    private func decide(_ routeId: String, save: Bool) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        do {
            if save { try RouteService.save(routeId: routeId, database: db) } else { try RouteService.dismiss(routeId: routeId, database: db) }
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reload() {
        guard preview == nil else { return }
        guard let db = AppModel.shared.displayDatabase else {
            model = RouteListModel(saved: [], suggested: [])
            placeCount = 0
            return
        }
        model = RouteCardLoader.list(database: db, battery: BatteryNowSource.current(database: db))
        placeCount = (try? RouteQueries(db).places().count) ?? 0
    }
}

/// Made-up routes for the CI ui-shots (`-uiShot routes-list`, `routes-empty`, `route-card`, `route-card-sparse`). No real places.
enum RoutesPreview {
    private static let monday: Int64 = 20_717
    private static let now: Int64 = monday * 86_400_000 + 12 * 3_600_000

    private static func ride(_ i: Int, daysAgo: Int, timeS: Double, used: Double?, variant: String?, elevation: Bool = true) -> RouteRideStats {
        RouteRideStats(rideId: "p\(i)", startAt: (monday - Int64(daysAgo)) * 86_400_000 + 8 * 3_600_000 + Int64(i) * 60_000, utcOffsetMin: 0,
                       variantId: variant, totalS: timeS, distanceM: 8_400, avgMovingMps: 6.2, usedPct: used,
                       elevGainM: elevation ? 38 : nil, elevLossM: elevation ? 35 : nil)
    }

    private static func line(_ shift: Double) -> [GeoPoint] {
        (0..<30).map { i -> GeoPoint in
            let x = Double(i)
            return GeoPoint(lat: 40.0 + x * 0.0005, lon: -75.0 + x * 0.0006 + shift * sin(x / 5))
        }
    }

    static func list(_ name: String) -> RouteListModel {
        guard name != "routes-empty" else { return RouteListModel(saved: [], suggested: []) }
        var busy: [RouteRideStats] = []
        for i in 0..<9 { busy.append(ride(i, daysAgo: i + 1, timeS: 1_080 + Double(i % 4) * 60, used: 10 + Double(i % 3), variant: "v1")) }
        let few = [ride(20, daysAgo: 3, timeS: 900, used: nil, variant: "v1"), ride(21, daysAgo: 1, timeS: 960, used: nil, variant: "v1")]
        if name == "routes-greyed" {
            // battery 20%, last seen 2 h ago: Home to Work fits one way only, the gym does not fit at all
            var gym: [RouteRideStats] = []
            for i in 0..<7 { gym.append(ride(40 + i, daysAgo: i + 2, timeS: 1_500, used: 18, variant: "v3")) }
            let battery = BatteryNow(pct: 20, ageMin: 120)
            return RouteListBuilder.build([
                RouteListInput(routeId: "a", title: "Home \u{2192} Work", state: .saved, rides: busy, nowMs: now, reverseRides: busy, battery: battery),
                RouteListInput(routeId: "b", title: "Home \u{2192} Gym", state: .saved, rides: gym, nowMs: now, battery: battery),
                RouteListInput(routeId: "c", title: "Route 3", state: .suggested, rides: few, nowMs: now, battery: battery)
            ])
        }
        return RouteListBuilder.build([
            RouteListInput(routeId: "a", title: "Home \u{2192} Work", state: .saved, rides: busy, nowMs: now),
            RouteListInput(routeId: "b", title: "Work \u{2192} Home", state: .saved, rides: Array(busy.prefix(4)), nowMs: now),
            RouteListInput(routeId: "c", title: "Route 3", state: .suggested, rides: few, nowMs: now)
        ])
    }

    /// `-uiShot route-arriveby` and the route card preview: 6 made-up workday rides in the morning
    static func arriveByRides() -> [RouteRideStats] {
        (0..<6).map { ride($0, daysAgo: $0 + 1, timeS: 780 + Double($0 % 3) * 60, used: 10, variant: "v1") }
    }

    /// `-uiShot places`: made-up places
    static func places() -> [PlaceRowModel] {
        [PlaceListBuilder.row(id: "p1", name: "Home", radiusM: nil, canCharge: true, routeCount: 3),
         PlaceListBuilder.row(id: "p2", name: "Work", radiusM: 200, canCharge: false, routeCount: 2),
         PlaceListBuilder.row(id: "p3", name: nil, radiusM: nil, canCharge: false, routeCount: 1)]
    }

    static func card(_ name: String) -> RouteCardModel {
        let variants = [VariantInfo(id: "v1", routeId: "a", name: "via Main Street", path: line(0), isReference: true),
                        VariantInfo(id: "v2", routeId: "a", name: "via Park Avenue", path: line(0.004))]
        if name == "route-card-sparse" {
            let rides = [ride(1, daysAgo: 3, timeS: 900, used: nil, variant: "v1", elevation: false),
                         ride(2, daysAgo: 1, timeS: 960, used: nil, variant: "v1", elevation: false)]
            return RouteCardBuilder.build(RouteCardInput(routeId: "c", fromName: nil, toName: nil, ordinal: 3, state: .suggested,
                                                         variants: [variants[0]], rides: rides, nowMs: now))
        }
        var rides: [RouteRideStats] = []
        for i in 0..<9 {
            rides.append(ride(i, daysAgo: 7 * (i + 1) % 80 + 1, timeS: 1_080 + Double(i % 4) * 60, used: 10 + Double(i % 3), variant: i < 6 ? "v1" : "v2"))
        }
        return RouteCardBuilder.build(RouteCardInput(routeId: "a", fromName: "Home", toName: "Work", ordinal: 1, state: .saved, variants: variants,
                                                     rides: rides, nowMs: now))
    }
}
