import CorckieCore
import SwiftUI

/// M1-14 Rides list, redesigned (P6-2 R1-R6, F-07): the rides sit in grouped bubbles, one bubble per group, and one "Sort by:" menu
/// chooses the groups (Date by default, remembered). A row is time, from → to, km, minutes, average speed, battery used and a chevron,
/// with the colour strip of the place the ride ended at. A search field finds a place name or a date. Short hops are one small
/// collapsible group at the end. Empty: "No rides yet"; nothing matches: "No rides match - Clear filters".
struct RidesListView: View {
    /// ui-shots: made-up rides instead of the stored ones
    var preview: [RideListItem]?
    /// ui-shots: made-up place colours (placeId to colour id)
    var previewColours: [String: String]?
    /// ui-shots: made-up place names (placeId to name)
    var previewNames: [String: String]?
    /// ui-shots: open with this sort
    var previewSort: RideSort?

    @State private var items: [RideListItem] = []
    /// B35: riding the scooter's odometer showed but no ride recorded
    @State private var gaps: [UntrackedGap] = []
    @State private var placeColours: [String: String] = [:]
    @State private var placeNames: [String: String] = [:]
    @State private var filter: RideDateFilter = .allTime
    @State private var query = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("rides.sort") private var sortRaw = RideSort.date.rawValue
    @State private var hopsOpen = false
    @State private var pendingDelete: RideListItem?
    @State private var errorText: String?
    @State private var selected: RideRoute?
    /// B57: discarded pieces of the last 30 days that can be restored
    @State private var discarded: [RideRecord] = []
    @State private var restoreOpen = false

    struct RideRoute: Hashable, Identifiable {
        let id: String
    }

    private var sort: RideSort { previewSort ?? RideSort(rawValue: sortRaw) ?? .date }

    private var model: RideGroups {
        RideListSorting.build(items, sort: sort, filter: filter, query: query, names: placeNames,
                              nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                              nowUtcOffsetMin: TimeZone.current.secondsFromGMT() / 60,
                              fallbackUtcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
    }

    var body: some View {
        NavigationStack {
            content
                .background(Theme.groupedBackground.ignoresSafeArea())
                .onAppear(perform: reload)
                .navigationTitle("Rides")
                .navigationBarTitleDisplayMode(.inline)   // G3: small title; G12: Settings only on Home
                .screen("Rides")
                .searchable(text: $query, prompt: "Place or date")
                .navigationDestination(item: $selected) { RideDetailView(rideId: $0.id) }
        }
        .onAppear(perform: reload)
        .onChange(of: ScreenSimulator.shared.active) { _, _ in reload() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reload() }
        .confirmationDialog("Delete this ride?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { ride in
            Button("Delete ride", role: .destructive) { delete(ride) }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("The ride and all its stored readings are removed. This cannot be undone.")
        }
        .sheet(isPresented: $restoreOpen, onDismiss: reload) {
            RestoreDiscardedSheet(rides: discarded)
        }
        .alert("Could not delete", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        let m = model
        if m.isEmpty {
            emptyCard(symbol: "list.bullet", title: "No rides yet", text: "Rides appear here by themselves after you ride.")
        } else if m.noMatch {
            VStack(spacing: 12) {
                controls
                emptyCard(symbol: "line.3.horizontal.decrease.circle", title: "No rides match", text: "",
                          action: ("Clear filters", { filter = .allTime; query = "" }))
            }
            .padding(.horizontal, DS.Space.gutter)
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
                List {
                    controls
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if !gaps.isEmpty {
                        Section {
                            ForEach(gaps) { gapRow($0) }
                        } header: {
                            SectionHeader("Not recorded").padding(.top, 0)
                        }
                    }
                    ForEach(m.groups, id: \.title) { group in
                        Section {
                            ForEach(group.rides, id: \.id) { row($0) }
                        } header: {
                            SectionHeader(group.title).padding(.top, 0)
                        }
                    }
                    if !m.shortHops.isEmpty {
                        Section {
                            DisclosureGroup("Short hops (\(m.shortHops.count))", isExpanded: $hopsOpen) {
                                ForEach(m.shortHops, id: \.id) { row($0, showDay: true) }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    if !discarded.isEmpty {
                        Section {
                            Button {
                                restoreOpen = true
                            } label: {
                                Label("Restore discarded ride", systemImage: "arrow.uturn.backward.circle")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .listRowBackground(Theme.row)
                        }
                    }
                    Color.clear.frame(height: 1).id("list-end")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .stiffBounce()
                .task {
                    // the ui-shot of the very bottom of a long list (B20)
                    guard UIShot.requested == "rides-long" else { return }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo("list-end", anchor: .bottom)
                }
            }
        }
    }

    private func emptyCard(symbol: String, title: String, text: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !text.isEmpty {
                Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The Date pill and the "Sort by:" menu
    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(RideDateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                pillLabel(symbol: "calendar", text: filter.rawValue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Date: \(filter.rawValue)")
            Menu {
                Picker("Sort by", selection: Binding(get: { sort }, set: { v in
                    Haptics.tick()
                    withAnimation(.smooth(duration: 0.35)) { sortRaw = v.rawValue }
                })) {
                    ForEach(RideSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                pillLabel(symbol: "arrow.up.arrow.down", text: "Sort by: \(sort.rawValue)")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sort by: \(sort.rawValue)")
            Spacer(minLength: 0)
        }
    }

    private func pillLabel(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            if !typeSize.isAccessibilitySize { Text(text).lineLimit(1) }     // big text: icon-only pills (the buttons keep their labels)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accentInk)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Theme.chip, in: Capsule())
        .frame(minHeight: DS.hit)
        .contentShape(Capsule())
    }

    /// F-08: a thin strip on the left of the row in the colour of the place the ride ended at (grey without a saved destination)
    private func placeStrip(_ ride: RideListItem) -> some View {
        let colour = ride.endPlaceId.flatMap { placeColours[$0] }
        return Capsule()
            .fill(colour.map { PlaceColourStore.color($0) } ?? Color(hex: PlaceColours.greyHex).opacity(0.5))
            .frame(width: 4)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    /// "Home → Work"; one side alone when only one place is saved; nil when neither
    private func routeText(_ ride: RideListItem) -> String? {
        let a = ride.startPlaceId.flatMap { placeNames[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        let b = ride.endPlaceId.flatMap { placeNames[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        switch (a, b) {
        case let (a?, b?): return "\(a) \u{2192} \(b)"
        case let (a?, nil): return "\(a) \u{2192} elsewhere"
        case let (nil, b?): return "elsewhere \u{2192} \(b)"
        default: return nil
        }
    }

    /// B35: a placeholder for riding that was not recorded. Not tappable: there is nothing but the distance.
    private func gapRow(_ gap: UntrackedGap) -> some View {
        let date = Date(timeIntervalSince1970: Double(gap.detectedAtMs) / 1000)
        let text = OdometerGap.rideRow(km: gap.km)
        return HStack(spacing: 10) {
            Image(systemName: "questionmark.circle").foregroundStyle(Theme.canyon).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.body.weight(.semibold))
                Text("Found on \(Self.timeText(date, offsetMin: TimeZone.current.secondsFromGMT() / 60, withDay: true))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .listRowBackground(Theme.row)
    }

    private func row(_ ride: RideListItem, showDay: Bool = false) -> some View {
        let offset = ride.utcOffsetMin ?? TimeZone.current.secondsFromGMT() / 60
        let date = Date(timeIntervalSince1970: Double(ride.startAt) / 1000)
        let withDay = showDay || sort != .date
        let timeLabel = Self.timeText(date, offsetMin: offset, withDay: withDay)
        return Button { selected = RideRoute(id: ride.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                placeStrip(ride)
                VStack(alignment: .leading, spacing: 3) {
                    if typeSize.isAccessibilitySize {
                        // largest text: the time, the places and the numbers each get their own lines (two at most for the long ones)
                        Text(timeLabel).font(.body.weight(.semibold)).lineLimit(2)
                        if let route = routeText(ride) { Text(route).font(.body).lineLimit(2) }
                    } else {
                        HStack(spacing: 8) {
                            Text(timeLabel).font(.body.weight(.semibold)).lineLimit(1).fixedSize()
                            if let route = routeText(ride) {
                                Text(route).font(.body).lineLimit(2).truncationMode(.tail)
                            }
                        }
                    }
                    Text(Self.figures(ride)).font(.footnote).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timeLabel), \(routeText(ride).map { $0 + ", " } ?? "")\(Self.figures(ride))")
        .accessibilityAddTraits(.isButton)
        .listRowBackground(Theme.row)
        .swipeActions {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete ride", systemImage: "trash") }
        }
    }

    private func reload() {
        if let preview {
            items = preview
            placeColours = previewColours ?? RidesPreview.placeColours
            placeNames = previewNames ?? RidesPreview.placeNames
            return
        }
        guard let db = AppModel.shared.displayDatabase else { items = []; return }
        gaps = ScreenSimulator.shared.active ? [] : GapStore.all(db)
        discarded = ScreenSimulator.shared.active ? [] : RideToolsService.restoreCandidates(db)     // B57
        let routes = RouteQueries(db)
        let ends = (try? routes.endPlaceIds()) ?? [:]
        let starts = (try? routes.startPlaceIds()) ?? [:]
        placeColours = PlaceColourStore.colours(database: db)
        var names: [String: String] = [:]
        for p in (try? routes.places()) ?? [] { if let n = p.name, !n.isEmpty { names[p.id] = n } }
        placeNames = names
        let rows = (try? RideQueries(db).rides()) ?? []
        items = rows.map {
            RideListItem(id: $0.id, startAt: $0.startAt, utcOffsetMin: $0.utcOffsetMin, kind: $0.kind,
                         distanceM: $0.distanceM, totalS: $0.totalS, endPlaceId: ends[$0.id],
                         startPlaceId: starts[$0.id], avgKmh: $0.avgMovingMps.map { $0 * 3.6 }, usedPct: Self.used($0))
        }
    }

    /// battery used: the stored figure, else rested start minus rested end
    private static func used(_ r: RideRecord) -> Double? {
        if let u = r.usedPct { return u }
        if let a = r.startRestPct, let b = r.endRestPct, a >= b { return a - b }
        return nil
    }

    private func delete(_ ride: RideListItem) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        do {
            try RideQueries(db).delete(rideId: ride.id)
            Haptics.warning()
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// R3: value and unit together on one line: "8.4 km · 25 min · 20 km/h · 4%" (parts a ride lacks are left out)
    static func figures(_ ride: RideListItem) -> String {
        var parts: [String] = []
        if let d = ride.distanceM { parts.append(String(format: "%.1f km", d / 1000)) }
        if let s = ride.totalS { parts.append("\(Int((s / 60).rounded())) min") }
        if let v = ride.avgKmh, v > 0 { parts.append("\(Int(v.rounded())) km/h") }
        if let u = ride.usedPct { parts.append("\(Int(u.rounded()))%") }
        return parts.isEmpty ? "No numbers yet" : parts.joined(separator: " \u{00B7} ")
    }

    static func detail(_ ride: RideListItem) -> String {
        var parts: [String] = []
        if let d = ride.distanceM { parts.append(String(format: "%.1f km", d / 1000)) }
        if let s = ride.totalS { parts.append("\(Int((s / 60).rounded())) min") }
        return parts.isEmpty ? "No numbers yet" : parts.joined(separator: " \u{00B7} ")
    }

    static func timeText(_ date: Date, offsetMin: Int, withDay: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone(secondsFromGMT: offsetMin * 60)
        f.dateFormat = withDay ? "d MMM, HH:mm" : "HH:mm"
        return f.string(from: date)
    }
}

/// Made-up rides for the CI ui-shots `rides-list`, `rides-colours`, `rides-sort-*` (not real places or days)
enum RidesPreview {
    /// made-up place colours (placeId to colour id) and names
    static let placeColours: [String: String] = ["home": "green", "work": "blue", "gym": "orange"]
    static let placeNames: [String: String] = ["home": "Home", "work": "Work", "gym": "Gym"]

    private static func ride(_ id: String, hoursAgo: Int64, km: Double, minutes: Double, from: String?, to: String?, used: Double?, kind: String = "ride") -> RideListItem {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = TimeZone.current.secondsFromGMT() / 60
        let avg: Double = minutes > 0 ? km / (minutes / 60) * 1.08 : 0
        return RideListItem(id: id, startAt: now - hoursAgo * 3_600_000, utcOffsetMin: offset, kind: kind,
                            distanceM: km * 1000, totalS: minutes * 60, endPlaceId: to, startPlaceId: from, avgKmh: avg, usedPct: used)
    }

    /// B20: 40 made-up rides over many days, long enough to scroll
    static func long() -> [RideListItem] {
        let places: [String?] = ["home", "work", "gym", nil]
        var items: [RideListItem] = []
        for i in 0..<40 {
            let km: Double = Double(4_000 + (i * 733) % 9_000) / 1000
            let minutes: Double = Double(900 + (i * 137) % 1_200) / 60
            items.append(ride("q\(i)", hoursAgo: Int64(2 + i * 19), km: km, minutes: minutes, from: places[i % 4], to: places[(i + 1) % 4],
                              used: Double(2 + (i * 3) % 9)))
        }
        return items
    }

    static func list() -> [RideListItem] {
        [
            ride("p1", hoursAgo: 2, km: 8.4, minutes: 25, from: "home", to: "work", used: 12),
            ride("p2", hoursAgo: 9, km: 5.4, minutes: 16, from: "work", to: "gym", used: 7),
            ride("p3", hoursAgo: 28, km: 12.1, minutes: 36, from: "gym", to: "home", used: 14),
            ride("p4", hoursAgo: 33, km: 7.9, minutes: 22, from: "home", to: "work", used: 9),
            ride("p5", hoursAgo: 52, km: 6.3, minutes: 19, from: "work", to: nil, used: 8),
            ride("p6", hoursAgo: 54, km: 1.2, minutes: 5, from: "home", to: "gym", used: 2, kind: "shortHop"),
            ride("p7", hoursAgo: 77, km: 9.8, minutes: 29, from: "home", to: "work", used: 11)
        ]
    }

    /// rides that ended at Home, Work, a gym and nowhere saved
    static func coloured() -> [RideListItem] { list() }
}

extension RidesPreview {
    /// `rides-sort-destination` and the like: the list opened with that Sort by
    static func sort(_ name: String) -> RideSort {
        switch name {
        case "rides-sort-destination": return .destination
        case "rides-sort-dayofweek": return .dayOfWeek
        case "rides-sort-timeofday": return .timeOfDay
        case "rides-sort-distance": return .distance
        case "rides-sort-duration": return .duration
        default: return .battery
        }
    }
}
