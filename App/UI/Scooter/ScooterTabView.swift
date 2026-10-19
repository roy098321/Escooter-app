import CorckieCore
import SwiftUI

/// M3-05: the Scooter tab. Status, info, links, and "Forget scooter" (clears the pairing only, never ride data).
struct ScooterTabView: View {
    /// Preview data for the ui-shot (no database, no Bluetooth).
    struct Preview {
        var record: ScooterRecord?
        var connected: Bool
        var lastSeenMs: Int64?
        var batteryPct: Int?
        var odometerKm: Double?
        /// V17: a made-up parked spot for the ui-shot
        var parked: ParkedSpot?
        var nowMs: Int64?
    }

    var preview: Preview?
    @State private var record: ScooterRecord?
    @State private var odometerKm: Double?
    @State private var rows: [MaintenanceService.Row] = []
    @State private var parked: ParkedSpot?
    @State private var confirmForget = false
    @State private var customName: String?
    @State private var renaming = false
    @State private var nameText = ""
    @State private var connectTap = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private let link = AppModel.shared.scooter

    private var connected: Bool { preview?.connected ?? link.connected }
    private var paired: Bool { preview != nil ? preview?.record != nil : (link.hasKnownScooter || record != nil) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.block) {
                    if paired {
                        pairedCards
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "scooter").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No scooter paired").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .glassCard(radius: DS.Radius.hero, padding: 0)
                        .opacity(0.75)
                    }
                }
                .padding(DS.Space.gutter)
            }
            .background { MapBackdrop().ignoresSafeArea() }
            .navigationTitle("Scooter")
            .navigationBarTitleDisplayMode(.inline)   // G3
            .toolbar {
                if paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        // S4: Forget scooter lives behind the dots, not as a big red button on the page
                        Menu {
                            Button { nameText = customName ?? record?.name ?? ""; renaming = true } label: { Label("Rename scooter", systemImage: "pencil") }
                            Button(role: .destructive) { confirmForget = true } label: { Label("Forget scooter", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .onAppear(perform: reload)
            .alert("Rename scooter", isPresented: $renaming) {
                TextField("Name", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveName() }
            } message: {
                Text("Only this app shows the name. An empty name goes back to the Bluetooth name.")
            }
            .confirmationDialog("Forget this scooter?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget scooter", role: .destructive, action: forget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only the pairing is removed. Your rides, routes and maintenance stay.")
            }
            .screen("Scooter")
        }
    }

    @ViewBuilder private var pairedCards: some View {
        let rec = preview != nil ? preview?.record : record
        let seenMs: Int64? = preview != nil ? preview?.lastSeenMs : LastSeen.load().ms
        let seenPct: Int? = preview != nil ? preview?.batteryPct : LastSeen.load().pct
        let odo = preview != nil ? preview?.odometerKm : odometerKm
        let livePct: Int? = preview != nil ? preview?.batteryPct : link.frame?.batteryPct
        let pct = connected ? (livePct ?? seenPct) : seenPct
        // S1 / S2 / S5: one status card: dot, name, odometer chip, the battery % (a clock when it is the last seen one), a small connect button
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        VStack(alignment: .leading, spacing: 8) {
        layout {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(connected ? Theme.ok : Theme.accent).frame(width: 9, height: 9)
                    Text(customName ?? rec?.name ?? "Scooter").font(.title3.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                if let odo {
                    InfoChip("gauge.with.dots.needle.67percent", String(format: "%.1f km", odo), label: "Odometer")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if !connected { Image(systemName: "clock").font(.footnote).foregroundStyle(.secondary) }
                Text(pct.map { "\($0)%" } ?? "\u{2013}").scaledFont(36, weight: .semibold, mono: true, relativeTo: .largeTitle)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connected ? "Battery \(pct ?? 0)%" : "Battery \(pct ?? 0)%, last seen \(Self.lastSeenText(seenMs))")
            if !connected {
                Button {
                    connectTap += 1
                    if preview == nil { link.start() }
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: DS.hit, height: DS.hit)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connect")
                .sensoryFeedback(.impact(weight: .medium), trigger: connectTap)
            }
        }
            if !connected, let seenMs {
                // the big % is the value from the last connection: say so, and when
                Text(Self.lastConnectedCaption(seenMs, nowMs: preview?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)      // P6-3: the card spans the full width when its content is stacked at big text sizes
        .padding(DS.Space.cardPad)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        parkedRow
        // S3: one row: what is due next
        NavigationLink { MaintenanceView() } label: {
            HStack {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
                Spacer()
                if let next = Self.nextDue(rows) {
                    Text(next.text).font(.subheadline).foregroundStyle(next.due ? Theme.accentInk : Color.secondary)
                }
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
        NavigationLink { BatteryView() } label: {
            HStack {
                Label("Battery", systemImage: "battery.75percent")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
    }

    /// V17: "Parked · Work · 2 h ago"; a tap opens the spot on a map
    @ViewBuilder private var parkedRow: some View {
        let spot = preview != nil ? preview?.parked : parked
        if let spot {
            let nowMs = preview?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            NavigationLink { ParkedMapView(spot: spot, nowMs: nowMs) } label: {
                HStack {
                    Label(ParkedText.line(spot, nowMs: nowMs), systemImage: "mappin.and.ellipse")
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a map")
        }
    }

    /// What is due next: an item that is due, else the one with the fewest km left ("Tyres \u{00B7} 120 km left")
    static func nextDue(_ rows: [MaintenanceService.Row]) -> (text: String, due: Bool)? {
        if let r = rows.first(where: { $0.status.isDue }) { return ("\(r.item.name) \u{00B7} \(Maintenance.statusText(r.status))", true) }
        let left: [(String, Double)] = rows.compactMap { r in
            if case .ok(let km) = r.status, let km { return (r.item.name, km) }
            return nil
        }
        guard let best = left.min(by: { $0.1 < $1.1 }) else { return nil }
        return ("\(best.0) \u{00B7} \(Int(best.1.rounded())) km left", false)
    }

    /// "When last connected · 6 h ago"; older than a day: the day and clock time
    static func lastConnectedCaption(_ ms: Int64, nowMs: Int64) -> String {
        let when = nowMs - ms < 24 * 3_600_000 ? ParkedText.ago(endedAtMs: ms, nowMs: nowMs) : lastSeenText(ms)
        return "When last connected {00B7} (when)"
    }

    static func lastSeenText(_ ms: Int64?) -> String {
        guard let ms else { return "Not yet" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: date)
    }

    static func batteryText(_ pct: Int?, live: Bool) -> String {
        guard let pct else { return "Unknown" }
        return live ? "\(pct) %" : "\(pct) % (when last seen)"
    }

    private func reload() {
        guard preview == nil, let db = AppModel.shared.database else { return }
        record = ScooterRecord.latest(in: db)
        customName = SettingsValue.text(db, Self.nameKey)
        odometerKm = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        rows = MaintenanceService.rows(db)
        parked = ParkedLoader.latest(database: db, simulated: false)
    }

    private func saveName() {
        let t = String(nameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard preview == nil, let db = AppModel.shared.database else { return }
        if t.isEmpty { SettingsValue.clear(db, Self.nameKey); customName = nil } else { SettingsValue.set(db, Self.nameKey, t); customName = t }
    }

    /// app-only name; the scooter itself is never written to
    static let nameKey = "scooter.customName"

    private func forget() {
        link.forget()
        if let db = AppModel.shared.database { ScooterRecord.forgetPairing(in: db) }
        record = nil
    }
}

enum ScooterPreview {
    static func make(_ name: String) -> ScooterTabView.Preview? {
        let rec = ScooterRecord(id: "preview", name: "Scooter", chip: "chip", firmware: "1.2.3", software: "4.5", firstSeenAt: 0)
        switch name {
        case "scooter-tab": return .init(record: rec, connected: true, lastSeenMs: nil, batteryPct: 58, odometerKm: 412.3,
                                         parked: ParkedSpot(lat: 40.0, lon: -75.0, endedAtMs: 1_790_000_000_000 - 2 * 3_600_000, placeName: "Work"),
                                         nowMs: 1_790_000_000_000)
        case "scooter-tab-off": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000, batteryPct: 58, odometerKm: 412.3)
        case "scooter-tab-none": return .init(record: nil, connected: false, lastSeenMs: nil, batteryPct: nil, odometerKm: nil)
        default: return nil
        }
    }
}
