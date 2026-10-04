import CorckieCore
import SwiftUI

/// M1-14 Rides list (IA: Rides tab). Newest ride on top under "Latest", the other rides grouped by day,
/// short hops collapsed in their own section, a date filter, delete with a confirmation.
/// Empty: pattern E "No rides yet"; filter matches nothing: S10 "No rides match - Clear filters".
struct RidesListView: View {
    @State private var items: [RideListItem] = []
    @State private var filter: RideDateFilter = .allTime
    @State private var hopsOpen = false
    @State private var pendingDelete: RideListItem?
    @State private var errorText: String?

    private var model: RideListModel {
        RideListLogic.build(items, filter: filter, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                            nowUtcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
    }

    var body: some View {
        NavigationStack {
            content
                .onAppear(perform: reload)
                .navigationTitle("Rides")
                .screen("Rides")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("Show", selection: $filter) {
                            ForEach(RideDateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
        }
        .onAppear(perform: reload)
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
            ContentUnavailableView("No rides yet", systemImage: "list.bullet",
                                   description: Text("Your rides appear here after you ride."))
        } else if m.noMatch {
            ContentUnavailableView {
                Label("No rides match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing in \(filter.rawValue.lowercased()).")
            } actions: {
                Button("Clear filters") { filter = .allTime }
            }
        } else {
            List {
                if let latest = m.latest {
                    Section("Latest") { row(latest) }
                }
                ForEach(m.days, id: \.day) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.rides, id: \.id) { row($0) }
                    }
                }
                if !m.shortHops.isEmpty {
                    Section {
                        DisclosureGroup("Short hops (\(m.shortHops.count))", isExpanded: $hopsOpen) {
                            ForEach(m.shortHops, id: \.id) { row($0, showDay: true) }
                        }
                    } footer: {
                        Text("0.5 to 2 km. Kept apart so they do not clutter your stats.")
                    }
                }
            }
        }
    }

    private func row(_ ride: RideListItem, showDay: Bool = false) -> some View {
        let offset = ride.utcOffsetMin ?? TimeZone.current.secondsFromGMT() / 60
        let date = Date(timeIntervalSince1970: Double(ride.startAt) / 1000)
        return NavigationLink {
            RideDetailView(rideId: ride.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeText(date, offsetMin: offset, withDay: showDay)).font(.body)
                Text(Self.detail(ride)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button(role: .destructive) { pendingDelete = ride } label: { Label("Delete ride", systemImage: "trash") }
        }
    }

    private func reload() {
        guard let db = AppModel.shared.database else { items = []; return }
        let rows = (try? RideQueries(db).rides()) ?? []
        items = rows.map {
            RideListItem(id: $0.id, startAt: $0.startAt, utcOffsetMin: $0.utcOffsetMin, kind: $0.kind,
                         distanceM: $0.distanceM, totalS: $0.totalS)
        }
    }

    private func delete(_ ride: RideListItem) {
        guard let db = AppModel.shared.database else { return }
        do {
            try RideQueries(db).delete(rideId: ride.id)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
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
