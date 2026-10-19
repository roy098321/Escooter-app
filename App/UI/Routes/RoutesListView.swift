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
    @State private var selected: RouteRef?
    @State private var showPlaces = false

    struct RouteRef: Hashable, Identifiable {
        let id: String
    }

    private var shown: RouteListModel { preview ?? model }

    var body: some View {
        NavigationStack {
            content
                .background { MapBackdrop().ignoresSafeArea() }
                .navigationTitle("Routes")
                .navigationBarTitleDisplayMode(.inline)   // G3: small title; G12: Settings only on Home
                .screen("Routes")
                .navigationDestination(item: $selected) { RouteCardView(routeId: $0.id) }
                .navigationDestination(isPresented: $showPlaces) { PlacesView() }
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
            VStack(spacing: 8) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.largeTitle).foregroundStyle(.secondary)
                Text("No routes yet").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .glassCard(radius: DS.Radius.hero, padding: 0)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 24)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            List {
                if !m.saved.isEmpty {
                    ForEach(m.saved, id: \.routeId) { row($0) }
                }
                if !m.suggested.isEmpty {
                    header("Suggested")
                    ForEach(m.suggested, id: \.routeId) { row($0) }
                }
                if placeCount > 0 || preview != nil {
                    Button { showPlaces = true } label: {
                        HStack {
                            Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.canyon).frame(width: 28)
                            Text("Places").font(.body.weight(.semibold))
                            Spacer()
                            if placeCount > 0 { Text("\(placeCount)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .padding(DS.Space.cardPad)
                        .glassCard(padding: 0)
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

    private func header(_ title: String) -> some View {
        SectionHeader(title)
            .padding(.horizontal, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.gutter, bottom: 0, trailing: DS.Space.gutter))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func row(_ r: RouteListRow) -> some View {
        Button { selected = RouteRef(id: r.routeId) } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(r.title).font(.body.weight(.semibold))
                        if let chip = r.fit.chip { chipView(chip, greyed: r.fit.greyed) }
                    }
                    facts(r)
                    if let detail = r.fit.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if r.state == .suggested {
                    Button("Save") { decide(r.routeId, save: true) }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: DS.hit)
                        .foregroundStyle(Theme.accentInk)
                        .background(Theme.chip, in: Capsule())
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save \(r.title)")
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .opacity(r.fit.greyed ? 0.55 : 1)
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    /// T4: labelled by an icon, one typical number each ("timer 19 min", "battery 11%"); a route still filling up shows its ride count
    private func facts(_ r: RouteListRow) -> some View {
        HStack(spacing: 6) {
            if let t = r.timeText { InfoChip("timer", t, label: "Time") }
            if let b = r.batteryText { InfoChip("battery.50percent", b, label: "Battery") }
            if r.timeText == nil { InfoChip("repeat", "\(r.rideCount) \(r.rideCount == 1 ? "ride" : "rides")") }
        }
    }

    private func chipView(_ text: String, greyed: Bool) -> some View {
        Pill(text: text, tint: greyed ? Color.secondary : Theme.accentInk)
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

    /// `-uiShot places`, `places-map`, `place-detail`: made-up places (synthetic coordinates, not real ones)
    static func places() -> [PlaceMapItem] {
        func item(_ id: String, _ name: String?, _ radius: Double?, _ charge: Bool, _ routes: Int, _ colour: String, _ lat: Double, _ lon: Double) -> PlaceMapItem {
            PlaceMapItem(id: id, row: PlaceListBuilder.row(id: id, name: name, radiusM: radius, canCharge: charge, routeCount: routes, colourId: colour),
                         lat: lat, lon: lon, colourId: colour)
        }
        return [item("p1", "Home", nil, true, 3, "green", 40.0105, -74.9885),
                item("p2", "Work", 200, false, 2, "blue", 40.0305, -74.9645),
                item("p3", nil, nil, false, 1, "orange", 40.0205, -74.9985)]
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
        var model = RouteCardBuilder.build(RouteCardInput(routeId: "a", fromName: "Home", toName: "Work", ordinal: 1, state: .saved, variants: variants,
                                                          rides: rides, otherDirection: rides, nowMs: now, battery: BatteryNow(pct: 31, ageMin: 90)))
        // M6-01: the Fastest combination section from the made-up choice-point rides (Q23)
        model.fastest = FastestCard.make(ChoiceSamples.answer(ChoiceSamples.nineRides).answer)
        return model
    }
}

extension RoutesPreview {
    /// F-06: made-up start / end places on the route card preview line (first and last point of `line`)
    static let pins: [PlacePin] = [
        PlacePin(id: "p1", name: "Home", lat: 40.0, lon: -75.0, colourId: "green"),
        PlacePin(id: "p2", name: "Work", lat: 40.0145, lon: -74.9826, colourId: "blue")
    ]
}
