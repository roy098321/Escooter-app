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
    @State private var confirmForget = false
    private let link = AppModel.shared.scooter

    private var connected: Bool { preview?.connected ?? link.connected }
    private var paired: Bool { preview != nil ? preview?.record != nil : (link.hasKnownScooter || record != nil) }

    var body: some View {
        NavigationStack {
            List {
                if paired {
                    pairedSections
                } else {
                    Section {
                        Text("No scooter paired. It is found again by itself next time it is on and near.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Scooter")
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

    @ViewBuilder private var pairedSections: some View {
        let rec = preview != nil ? preview?.record : record
        let seenMs: Int64? = preview != nil ? preview?.lastSeenMs : LastSeen.load().ms
        let seenPct: Int? = preview != nil ? preview?.batteryPct : LastSeen.load().pct
        let odo = preview != nil ? preview?.odometerKm : odometerKm
        let livePct: Int? = preview != nil ? preview?.batteryPct : link.frame?.batteryPct
        Section("Status") {
            LabeledContent("Connection", value: connected ? "Connected" : "Not connected")
            if !connected {
                LabeledContent("Last seen", value: Self.lastSeenText(seenMs))
            }
            LabeledContent("Battery", value: Self.batteryText(connected ? (livePct ?? seenPct) : seenPct, live: connected))
        }
        Section("Info") {
            LabeledContent("Model", value: rec?.name ?? "Unknown")
            LabeledContent("Firmware", value: rec?.fingerprint ?? "Read at the next connection")
            LabeledContent("Odometer", value: odo.map { String(format: "%.1f km", $0) } ?? "After the first ride")
        }
        Section {
            NavigationLink("Maintenance") { MaintenanceView() }
            LabeledContent("Battery health", value: "Coming soon")
        }
        Section {
            Button("Forget scooter", role: .destructive) { confirmForget = true }
        } footer: {
            Text("Removes the pairing only. Rides and routes are never deleted.")
        }
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
