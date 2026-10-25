import CorckieCore
import SwiftUI

/// B57: "Restore discarded ride". The app keeps discarded pieces (kind `discarded`, hidden); this sheet lists the last 30 days
/// with their time, distance (the GPS one when it saw more) and length, and turns one back into a ride.
struct RestoreDiscardedSheet: View {
    let rides: [RideRecord]
    @Environment(\.dismiss) private var dismiss
    @State private var restored: Set<String> = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rides, id: \.id) { row($0) }
                } footer: {
                    Text("Pieces the app set aside in the last 30 days. Restoring one puts it back in your rides.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Discarded rides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Could not restore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ r: RideRecord) -> some View {
        let date = Date(timeIntervalSince1970: Double(r.startAt) / 1000)
        let done = restored.contains(r.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.body.weight(.semibold))
                Text(figures(r)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if done {
                Label("Restored", systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button("Restore") { restore(r) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func figures(_ r: RideRecord) -> String {
        var parts: [String] = []
        let gps = AppModel.shared.database.map { RideToolsService.gpsDistanceM($0, rideId: r.id) } ?? 0
        let d = max(r.distanceM ?? 0, gps)
        parts.append(RideSummaryBuilder.distance(d) + (gps > (r.distanceM ?? 0) ? " (GPS)" : ""))
        if let s = r.totalS, s > 0 { parts.append(RideSummaryBuilder.duration(s)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func restore(_ r: RideRecord) {
        guard let db = AppModel.shared.database else { return }
        do {
            try RideToolsService.restoreDiscarded(db, rideId: r.id)
            restored.insert(r.id)
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
