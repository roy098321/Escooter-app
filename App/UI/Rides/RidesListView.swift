import CorckieCore
import SwiftUI

/// M1-14 Rides list (IA: Rides tab). Newest ride on top under "Latest", the other rides grouped by day,
/// short hops collapsed in their own section, a date filter, delete with a confirmation.
/// Empty: pattern E "No rides yet"; filter matches nothing: S10 "No rides match - Clear filters".
/// UI overhaul (UI_PLAN 3.4): glass rows over the map backdrop, a Date pill, a Compare pill. Only data the app already has
/// (time, km, minutes, short hop); route names and battery per row are V2 backlog.
struct RidesListView: View {
    /// ui-shots: made-up rides instead of the stored ones
    var preview: [RideListItem]?
    /// ui-shots: made-up place colours (placeId to colour id)
    var previewColours: [String: String]?

    @State private var items: [RideListItem] = []
    @State private var placeColours: [String: String] = [:]
    @State private var filter: RideDateFilter = .allTime
    @State private var hopsOpen = false
    @State private var pendingDelete: RideListItem?
    @State private var errorText: String?
    @State private var selected: RideRoute?
    @State private var showCompare = false

    struct RideRoute: Hashable, Identifiable {
        let id: String
    }

    private var model: RideListModel {
        RideListLogic.build(items, filter: filter, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                            nowUtcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
    }

    var body: some View {
        NavigationStack {
            content
                .background { MapBackdrop().ignoresSafeArea() }
                .onAppear(perform: reload)
                .navigationTitle("Rides")
                .navigationBarTitleDisplayMode(.inline)   // G3: small title; G12: Settings only on Home
                .screen("Rides")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.shownCount >= 2 {
                            Button { showCompare = true } label: {
                                Text("Compare")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 40)
                                    .sunPanel(Capsule(), thin: true)
                                    .frame(minHeight: DS.hit)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Compare your latest ride with another one")
                        }
                    }
                }
                .navigationDestination(item: $selected) { RideDetailView(rideId: $0.id) }
        }
        .onAppear(perform: reload)
        .onChange(of: ScreenSimulator.shared.active) { _, _ in reload() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reload() }
        .sheet(isPresented: $showCompare) {
            if let id = model.latest?.id ?? model.days.first?.rides.first?.id {
                CompareSheet(rideId: id).glassPresentation()
            }
        }
        .confirmationDialog("Delete this ride?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { ride in
            Button("Delete ride", role: .destructive) { delete(ride) }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("The ride and all its stored readings are removed. This cannot be undone.")
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
                filterPill
                emptyCard(symbol: "line.3.horizontal.decrease.circle", title: "No rides match",
                          text: "Nothing in \(filter.rawValue.lowercased()).", action: ("Clear filters", { filter = .allTime }))
            }
            .padding(.horizontal, DS.Space.gutter)
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
            List {
                filterPill
                    .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if let latest = m.latest {
                    header("Latest")
                    row(latest, latest: true)
                }
                ForEach(m.days, id: \.day) { group in
                    header(Self.dayTitle(group.day))
                    ForEach(group.rides, id: \.id) { row($0) }
                }
                if !m.shortHops.isEmpty {
                    shortHopsHeader(m.shortHops.count)
                    if hopsOpen {
                        ForEach(m.shortHops, id: \.id) { row($0, showDay: true) }
                    }
                    Text("0.5 to 2 km. Kept apart so they do not clutter your stats.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter + 4, bottom: 24, trailing: DS.Space.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Color.clear.frame(height: 1).id("list-end")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
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
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The Date pill: opens the same four choices the old toolbar menu had
    private var filterPill: some View {
        HStack {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(RideDateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(filter.rawValue)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .sunPanel(Capsule(), thin: true)
                .frame(minHeight: DS.hit)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Date: \(filter.rawValue)")
            Spacer(minLength: 0)
        }
    }

    private func header(_ title: String) -> some View {
        SectionHeader(title)
            .padding(.horizontal, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.gutter, bottom: 0, trailing: DS.Space.gutter))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func shortHopsHeader(_ count: Int) -> some View {
        Button { withAnimation { hopsOpen.toggle() } } label: {
            HStack {
                Text("Short hops (\(count))").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: hopsOpen ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
        .accessibilityValue(hopsOpen ? "Open" : "Closed")
        .listRowInsets(EdgeInsets(top: 12, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func ridePills(latest: Bool, showDay: Bool, ride: RideListItem) -> some View {
        if latest { Pill(text: "Latest") }
        if ride.kind == "shortHop" && !showDay { Pill(text: "Short hop", tint: .secondary) }
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

    private func row(_ ride: RideListItem, showDay: Bool = false, latest: Bool = false) -> some View {
        let offset = ride.utcOffsetMin ?? TimeZone.current.secondsFromGMT() / 60
        let date = Date(timeIntervalSince1970: Double(ride.startAt) / 1000)
        let (km, minutes) = Self.numbers(ride)
        return Button { selected = RideRoute(id: ride.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                placeStrip(ride)
                VStack(alignment: .leading, spacing: 3) {
                    let time = Text(Self.timeText(date, offsetMin: offset, withDay: showDay)).font(.body.weight(.semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { time.lineLimit(1).fixedSize(); ridePills(latest: latest, showDay: showDay, ride: ride) }
                        VStack(alignment: .leading, spacing: 4) { time.lineLimit(1).fixedSize(); HStack(spacing: 8) { ridePills(latest: latest, showDay: showDay, ride: ride) } }
                    }
                    Text(minutes).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(km).font(.body.weight(.semibold)).monospacedDigit()
                    Text("km").font(.footnote).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.timeText(date, offsetMin: offset, withDay: showDay)), \(Self.detail(ride))")
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets(top: 4, leading: DS.Space.gutter, bottom: 4, trailing: DS.Space.gutter))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete ride", systemImage: "trash") }
        }
    }

    private func reload() {
        if let preview { items = preview; placeColours = previewColours ?? [:]; return }
        guard let db = AppModel.shared.displayDatabase else { items = []; return }
        let ends = (try? RouteQueries(db).endPlaceIds()) ?? [:]
        placeColours = PlaceColourStore.colours(database: db)
        let rows = (try? RideQueries(db).rides()) ?? []
        items = rows.map {
            RideListItem(id: $0.id, startAt: $0.startAt, utcOffsetMin: $0.utcOffsetMin, kind: $0.kind,
                         distanceM: $0.distanceM, totalS: $0.totalS, endPlaceId: ends[$0.id])
        }
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

    /// The two figures of a row: "8.4" and "25 min" ("-" when the ride has no numbers yet)
    static func numbers(_ ride: RideListItem) -> (km: String, minutes: String) {
        let km = ride.distanceM.map { String(format: "%.1f", $0 / 1000) } ?? "\u{2013}"
        let minutes = ride.totalS.map { "\(Int(($0 / 60).rounded())) min" } ?? "No numbers yet"
        return (km, minutes)
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

    /// "yyyy-MM-dd" to "Tue 7 Oct"
    static func dayTitle(_ key: String) -> String {
        let p = DateFormatter()
        p.dateFormat = "yyyy-MM-dd"
        p.timeZone = TimeZone(secondsFromGMT: 0)
        guard let d = p.date(from: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }
}

/// Made-up rides for the CI ui-shot `rides-list` (not real places or days)
enum RidesPreview {
    /// B20: 40 made-up rides over many days, long enough to scroll
    static func long() -> [RideListItem] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let h: Int64 = 3_600_000
        let offset = TimeZone.current.secondsFromGMT() / 60
        var items: [RideListItem] = []
        for i in 0..<40 {
            let hoursAgo: Int64 = Int64(2 + i * 19)
            let metres: Double = Double(4_000 + (i * 733) % 9_000)
            let seconds: Double = Double(900 + (i * 137) % 1_200)
            items.append(RideListItem(id: "q\(i)", startAt: now - hoursAgo * h, utcOffsetMin: offset, kind: "ride", distanceM: metres, totalS: seconds))
        }
        return items
    }

    static func list() -> [RideListItem] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let h: Int64 = 3_600_000
        let offset = TimeZone.current.secondsFromGMT() / 60
        return [
            RideListItem(id: "p1", startAt: now - 2 * h, utcOffsetMin: offset, kind: "ride", distanceM: 8_400, totalS: 1_500),
            RideListItem(id: "p2", startAt: now - 9 * h, utcOffsetMin: offset, kind: "ride", distanceM: 5_400, totalS: 980),
            RideListItem(id: "p3", startAt: now - 28 * h, utcOffsetMin: offset, kind: "ride", distanceM: 12_100, totalS: 2_160),
            RideListItem(id: "p4", startAt: now - 33 * h, utcOffsetMin: offset, kind: "ride", distanceM: 7_900, totalS: 1_320),
            RideListItem(id: "p5", startAt: now - 52 * h, utcOffsetMin: offset, kind: "ride", distanceM: 6_300, totalS: 1_140),
            RideListItem(id: "p6", startAt: now - 54 * h, utcOffsetMin: offset, kind: "shortHop", distanceM: 1_200, totalS: 300),
            RideListItem(id: "p7", startAt: now - 77 * h, utcOffsetMin: offset, kind: "ride", distanceM: 9_800, totalS: 1_740)
        ]
    }
}

extension RidesPreview {
    /// F-08: made-up place colours for `-uiShot rides-colours`
    static let placeColours: [String: String] = ["home": "green", "work": "blue", "gym": "orange"]

    /// rides that ended at Home, Work, a gym and nowhere saved
    static func coloured() -> [RideListItem] {
        var items = list()
        let ends: [String?] = ["work", "home", "work", nil, "gym", "home", "work"]
        for i in items.indices { items[i].endPlaceId = ends[i] }
        return items
    }
}
