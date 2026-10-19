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
    }

    var preview: Preview?
    @State private var record: ScooterRecord?
    @State private var odometerKm: Double?
    @State private var rows: [MaintenanceService.Row] = []
    @State private var confirmForget = false
    @State private var connectTap = 0
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
                            Text("It is found again by itself next time it is on and near.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            .onAppear(perform: reload)
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
        // hero card: name, connection line, battery
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rec?.name ?? "Scooter").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(connected ? "Connected" : "Not connected").font(.subheadline)
                }
                if !connected {
                    Text("Last seen \(Self.lastSeenText(seenMs))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(pct.map { "\($0)%" } ?? "\u{2013}").scaledFont(36, weight: .semibold, mono: true, relativeTo: .largeTitle)
                    .minimumScaleFactor(0.6)
                Text(connected ? "battery" : "when last seen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.cardPad)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .opacity(connected ? 1 : 0.8)
        .accessibilityElement(children: .combine)
        if !connected {
            Button {
                connectTap += 1
                if preview == nil { link.start() }
            } label: {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: DS.hit)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .sensoryFeedback(.impact(weight: .medium), trigger: connectTap)
        }
        StatTileGrid {
            StatTile(value: odo.map { String(format: "%.1f", $0) } ?? "\u{2013}", label: odo == nil ? "km total (after the first ride)" : "km total")
        }
        SectionHeader("Maintenance")
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Tyres, brakes and bolts, counted in scooter kilometres.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider() }
                HStack {
                    Text(row.item.name)
                    Spacer()
                    if row.status.isDue {
                        Pill(text: Maintenance.statusText(row.status), tint: .orange)
                    } else {
                        Text(Maintenance.statusText(row.status)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)
            }
            Divider()
            NavigationLink { MaintenanceView() } label: {
                HStack { Text("Open maintenance"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary) }
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.cardPad)
        .glassCard(padding: 0)
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
        Button(role: .destructive) { confirmForget = true } label: {
            Text("Forget scooter").frame(maxWidth: .infinity, minHeight: DS.hit)
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
        Text("Removes the pairing only. Rides and routes are never deleted.")
            .font(.footnote).foregroundStyle(.secondary)
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
        odometerKm = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        rows = MaintenanceService.rows(db)
    }

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
        case "scooter-tab": return .init(record: rec, connected: true, lastSeenMs: nil, batteryPct: 58, odometerKm: 412.3)
        case "scooter-tab-off": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000, batteryPct: 58, odometerKm: 412.3)
        case "scooter-tab-none": return .init(record: nil, connected: false, lastSeenMs: nil, batteryPct: nil, odometerKm: nil)
        default: return nil
        }
    }
}
