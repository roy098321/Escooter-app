import Charts
import CorckieCore
import MapKit
import SwiftUI

/// M2-04: the route card (CONCEPT: saved route view). Top to bottom: title and the ride count, the map with the usual path (other
/// variants dashed), six stats as ranges, the Today strip, variants, elevation both ways, the rides on this route. Sections with
/// nothing to show are left out (STATES S9). All text comes from CorckieCore (`RouteCardBuilder`); this view only draws it.
/// Later milestones add: Arrive by and there-and-back (M2-07 / M2-09), choice points and the fastest combination (M6), factors (M4).
struct RouteCardView: View {
    @ScaledMetric(relativeTo: .body) private var tileMin: CGFloat = 150
    var routeId: String?
    var preview: RouteCardModel?

    @State private var model: RouteCardModel?
    @State private var missing = false
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var confirmRemove = false
    @State private var saveTap = 0
    @State private var errorText: String?
    @State private var arriveInfo: (rides: [RouteRideStats], destination: String)?
    @State private var previewFollow = false
    @State private var pins: [PlacePin] = []
    /// Hotfix .14 (N12-7, owner 27 Nov): the card pulls down like the ride screen's (one line, or the map only)
    @State private var cardDetent: CardDetent = .standard
    /// N12-7: a way the rider tapped (map or list): it lights up instead of the fastest; nil = the fastest
    @State private var selectedWay: String?
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
        .toolbar(.hidden, for: .navigationBar)
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

    /// K1: the plain ride count as the subtitle
    static func subtitle(_ m: RouteCardModel) -> String {
        let rides = "\(m.totalRides) \(m.totalRides == 1 ? "ride" : "rides")"
        return m.saved ? rides : "Suggested \u{00B7} " + rides
    }

    private func mapPlan(_ m: RouteCardModel) -> RouteMapPlan {
        let combo = m.fastest.flatMap { $0.filling ? nil : $0.path }
        return RouteMapPlan.make(m.map, combination: combo, selected: selectedWay)
    }

    /// N12-7: the one line when the card is pulled down ("Fastest 31 min · usual 35 min · 14.4 km")
    static func oneLine(_ m: RouteCardModel, _ plan: RouteMapPlan) -> String {
        var parts: [String] = []
        if let chip = plan.ways.last(where: { $0.isMain })?.chip { parts.append(chip) }
        for s in m.stats where !s.filling && (s.label == "Time" || s.label == "Distance") {
            parts.append((s.typical ?? s.value).replacingOccurrences(of: "~", with: ""))
        }
        return parts.isEmpty ? m.title : parts.joined(separator: " \u{00B7} ")
    }

    private func content(_ m: RouteCardModel) -> some View {
        let plan = mapPlan(m)
        return RideCardScreen(detent: $cardDetent) {
            if m.map.isEmpty {
                MapBackdrop(map: true)
            } else {
                mapView(m.map, plan: plan)
            }
        } topBar: {
            GlassTopBar(title: m.title, subtitle: Self.subtitle(m)) {
                GlassIconButton(symbol: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                Menu {
                    Button { nameDraft = (preview ?? model)?.title ?? ""; showRename = true } label: { Label("Rename route", systemImage: "pencil") }
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove route", systemImage: "trash") }
                } label: {
                    GlassIcon(symbol: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        } side: {
            EmptyView()
        } line: {
            Text(Self.oneLine(m, plan))
                .font(.headline).fontDesign(.rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !m.saved { suggestionCard }
                if let id = selectedWay, let v = m.variants.first(where: { $0.id == id }) {
                    selectedWayCard(v, plan: plan)
                } else if let f = m.fastest {
                    fastestCard(f)   // N12-7: the fastest combination first
                }
                todayCard(m.today)
                statTiles(m)
                if m.saved { arriveBy(m) }
                if let t = m.thereAndBack { thereAndBackCard(t) }
                if !m.variants.isEmpty { variantsCard(m.variants, plan: plan) }
                if let e = m.elevation { elevationCard(e) }
                ridesCard(m)
            }
            .padding(.top, 2)
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
            Text(t.headline).scaledFont(20, weight: .semibold)
            Text(t.detail).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
        .accessibilityElement(children: .combine)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save as route?").font(.headline)
            HStack(spacing: 12) {
                Button("Save route") { saveTap += 1; setSaved(true) }.buttonStyle(.borderedProminent)
                    .onChange(of: saveTap) { _, _ in Haptics.success(); SoundPlayer.shared.play(.saved) }
                Button("Not a route") { setSaved(false) }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
    }

    /// N12-7 (owner 27 Nov): no dotted lines. The fastest way (or the tapped one) is the main line, thick with a dark edge and its
    /// chip ("Fastest · 31 min"), arrows show the direction; the other ways are thin and grey with "+4 min". Tap a chip to choose it.
    private func mapView(_ lines: [RouteMapLine], plan: RouteMapPlan) -> some View {
        Map(initialPosition: Self.position(lines, sheet: true), interactionModes: [.pan, .zoom]) {
            ForEach(Array(plan.ways.enumerated()), id: \.offset) { _, w in
                let coords = w.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if w.isMain {
                    MapPolyline(coordinates: coords)
                        .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: coords)
                        .stroke(followingCombination && w.variantId == nil ? Theme.ok : Theme.accent,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                } else {
                    MapPolyline(coordinates: coords)
                        .stroke(Color.gray.opacity(0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(Array(plan.arrows.enumerated()), id: \.offset) { _, a in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: a.at.lat, longitude: a.at.lon), anchor: .center) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(a.bearingDeg))
                        .accessibilityHidden(true)
                }
            }
            PlacePinMarks(pins: preview != nil ? RoutesPreview.pins : pins)
            ForEach(Array(plan.ways.enumerated()), id: \.offset) { _, w in
                if let chip = w.chip, let at = w.chipAt {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: at.lat, longitude: at.lon), anchor: .center) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { selectedWay = w.isMain ? nil : w.variantId }
                        } label: {
                            Text(chip)
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(w.isMain ? Theme.accent : Color.black.opacity(0.8), in: Capsule())
                                .foregroundStyle(w.isMain ? Theme.onAccent : Color.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(w.isMain ? chip : "\(w.name), \(chip). Show this way")
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Map of the route")
    }

    /// N12-7: the tapped way's own card, and the way back to the fastest
    private func selectedWayCard(_ v: RouteVariantRow, plan: RouteMapPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v.name).font(.caption.weight(.bold)).foregroundStyle(Theme.accentInk).textCase(.uppercase)
            Text(v.timeText).scaledFont(24, weight: .semibold, mono: true)
            HStack(spacing: 8) {
                if let chip = plan.ways.first(where: { $0.variantId == v.id })?.chip, chip.hasPrefix("+") {
                    Text("\(chip) than the fastest").font(.subheadline)
                }
                Text("\(v.rides) \(v.rides == 1 ? "ride" : "rides")").font(.subheadline).foregroundStyle(.secondary)
                if let b = v.batteryText { Text(b).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            }
            Button { withAnimation(.easeInOut(duration: 0.25)) { selectedWay = nil } } label: {
                Label("Show the fastest again", systemImage: "arrow.uturn.backward")
            }
            .font(.subheadline.weight(.semibold))
            .tint(Theme.accentInk)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// K3: today's time as one big number, the leaving time and the battery as two chips
    @ViewBuilder private func todayCard(_ t: RouteTodayStrip) -> some View {
        if let time = t.timeText {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.subheadline).foregroundStyle(.secondary)
                    Text(time).scaledFont(30, weight: .bold, mono: true, relativeTo: .title)
                }
                ChipFlow(spacing: 6) {
                    if let d = t.departure { InfoChip("clock", d, label: "Leaving") }
                    if let b = t.batteryText { InfoChip("battery.50percent", b, label: "Battery") }
                    if t.rushHour { Pill(text: "Rush hour") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.cardPad)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            Label("Not enough rides", systemImage: "hourglass")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
        }
    }

    /// K2 / G5 / G11: one typical number per tile, labels only; a stat that is still filling up is not drawn; the ranges sit behind the ⓘ
    @ViewBuilder private func statTiles(_ m: RouteCardModel) -> some View {
        let ready = m.stats.filter { !$0.filling }
        if !ready.isEmpty {
            SectionHeader("Usual") {
                InfoButton("Usual range", info: InfoContent(
                    lead: "The range each usual number moves in on this route.",
                    basedOn: ready.map { InfoBasedOn($0.label, $0.value) } + [InfoBasedOn("Based on", "\(m.totalRides) \(m.totalRides == 1 ? "ride" : "rides")")]))
            }
            StatTileGrid {
                ForEach(Array(ready.enumerated()), id: \.offset) { _, s in
                    StatTile(value: (s.typical ?? s.value).replacingOccurrences(of: "~", with: ""), label: s.label)
                }
            }
        }
    }

    /// K4: Variants is folded
    private func variantsCard(_ rows: [RouteVariantRow], plan: RouteMapPlan) -> some View {
        DisclosureGroup {
            variantRows(rows, plan: plan).padding(.top, 8)
        } label: {
            Text("Ways \u{00B7} \(rows.count)").font(.headline)
        }
        .tint(Theme.canyon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
    }

    private func variantRows(_ rows: [RouteVariantRow], plan: RouteMapPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, v in
                if i > 0 { Divider() }
                let way = plan.ways.first { $0.variantId == v.id }
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedWay = selectedWay == v.id || (selectedWay == nil && way?.isMain == true) ? nil : v.id
                    }
                } label: {
                HStack {
                    Capsule().fill(way?.isMain == true ? Theme.accent : Color.gray.opacity(0.75)).frame(width: 18, height: 4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name)
                        Text(way?.chip.flatMap { $0.hasPrefix("+") ? $0 : nil } ?? (v.isReference ? "Usual way" : "Other way"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(v.timeText).monospacedDigit()
                        if let b = v.batteryText { Text(b).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows this way on the map")
            }
        }
    }

    /// M6-01 (Q23): the next ride follows the combination of this route (Home's Where to? shows the route selected)
    private var followingCombination: Bool {
        if preview != nil { return previewFollow }
        guard let id = routeId else { return false }
        return RouteFollowSelection.shared.routeId == id && RouteFollowSelection.shared.combination
    }

    private func fastestCard(_ f: FastestCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(f.headline)
                .scaledFont(20, weight: .semibold, mono: true)
                .foregroundStyle(f.filling ? Color.secondary : Color.primary)
            Text(f.detail).font(.subheadline)
            if let n = f.note { Text(n).font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(f.waiting.enumerated()), id: \.offset) { _, w in
                Text(w).font(.caption).foregroundStyle(.secondary)
            }
            if f.canFollow {
                Button {
                    if preview != nil {
                        previewFollow.toggle()
                    } else if let id = routeId {
                        RouteFollowSelection.shared.followCombination(id)
                    }
                } label: {
                    Label(followingCombination ? "Following on the next ride" : "Follow this next ride",
                          systemImage: followingCombination ? "checkmark.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(followingCombination ? Theme.ok : Theme.accentInk)
                .padding(.top, 4)
                .accessibilityHint("The next ride follows this combination. Only ways you have ridden before.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
        .accessibilityElement(children: .contain)
    }

    /// K4 / G5: Elevation is folded, no "~", no footer
    private func elevationCard(_ e: RouteElevationModel) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(e.thisWay.replacingOccurrences(of: "~", with: "")).font(.subheadline).monospacedDigit()
                Text(e.otherWay.replacingOccurrences(of: "~", with: "")).font(.subheadline)
                    .foregroundStyle(e.otherIsEstimate ? Color.secondary : Color.primary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Elevation").font(.headline)
        }
        .tint(Theme.canyon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
    }

    static func position(_ lines: [RouteMapLine], sheet: Bool = false) -> MapCameraPosition {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for l in lines {
            for p in l.points {
                minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
                minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
            }
        }
        guard minLat <= maxLat else { return .automatic }
        // with the sheet over the lower half, frame the route in the upper part (wider span, centre moved south)
        let latSpan = max(0.004, (maxLat - minLat) * (sheet ? 2.2 : 1.3))
        let lonSpan = max(0.004, (maxLon - minLon) * (sheet ? 1.5 : 1.3))
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 - (sheet ? latSpan * 0.2 : 0), longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
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
        pins = PlaceMapLoader.pins(routeId: id, database: db)
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
