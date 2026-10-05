import CorckieCore
import SwiftUI

/// M2-04: the Routes tab (IA: Routes tab). Saved routes with their rides and usual ranges, then "Suggested routes" (shown only when
/// there are any). Empty: pattern E. Greying with the safety margin, chips and Places come in M2-05. All text is made in
/// CorckieCore (`RouteListBuilder`).
struct RoutesListView: View {
    var preview: RouteListModel?

    @State private var model = RouteListModel(saved: [], suggested: [])

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
    }

    @ViewBuilder private var content: some View {
        let m = shown
        if m.isEmpty {
            ContentUnavailableView("No routes yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text("Ride the same trip twice and you'll be asked to save it."))
        } else {
            List {
                if !m.saved.isEmpty {
                    Section("Routes") {
                        ForEach(m.saved, id: \.routeId) { row($0) }
                    }
                }
                if !m.suggested.isEmpty {
                    Section {
                        ForEach(m.suggested, id: \.routeId) { row($0) }
                    } header: {
                        Text("Suggested routes")
                    } footer: {
                        Text("Trips you rode more than once. Open one to save it or say it is not a route.")
                    }
                }
            }
        }
    }

    private func row(_ r: RouteListRow) -> some View {
        NavigationLink {
            RouteCardView(routeId: r.routeId)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.body)
                Text(r.summary).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        guard preview == nil else { return }
        guard let db = AppModel.shared.displayDatabase else {
            model = RouteListModel(saved: [], suggested: [])
            return
        }
        model = RouteCardLoader.list(database: db)
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
        return RouteListBuilder.build([
            RouteListInput(routeId: "a", title: "Home \u{2192} Work", state: .saved, rides: busy, nowMs: now),
            RouteListInput(routeId: "b", title: "Work \u{2192} Home", state: .saved, rides: Array(busy.prefix(4)), nowMs: now),
            RouteListInput(routeId: "c", title: "Route 3", state: .suggested, rides: few, nowMs: now)
        ])
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
