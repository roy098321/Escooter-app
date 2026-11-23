import CorckieCore
import SwiftUI

/// N11-2 · O4 Garage (owner 23 Nov, auto-first). The active scooter is simply the one that is connected: no switcher.
/// Each scooter keeps its own battery, charge log, calibration, faults and maintenance; places, routes, prices and settings are shared.
/// Leaving: Sold / Lost (no nearby notification) / Remove; nothing is deleted, the service book still exports.
struct GarageView: View {
    @State private var registry = GarageRegistry()
    @State private var rides: [String: Int] = [:]
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(registry.inUse) { s in
                    NavigationLink { GarageScooterView(scooterId: s.id) } label: { row(s) }
                }
                Button { adding = true } label: { Label("Add another scooter", systemImage: "plus.circle") }
            } footer: {
                Text("The scooter you switch on is the one the app uses.")
            }
            let gone = registry.scooters.filter { $0.status.isRetired }
            if !gone.isEmpty {
                Section("Sold, lost or removed") {
                    ForEach(gone) { s in
                        NavigationLink { GarageScooterView(scooterId: s.id) } label: { row(s) }
                    }
                }
            }
        }
        .navigationTitle("Garage")
        .onAppear(perform: load)
        .sheet(isPresented: $adding, onDismiss: load) { AddScooterSheet() }
        .screen("Garage")
    }

    private func row(_ s: GarageScooter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.displayName).font(.headline)
            Text(line(s)).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ s: GarageScooter) -> String {
        var parts: [String] = []
        if s.name != nil { parts.append(s.model) }
        if let label = s.status.label {
            parts.append(label)
        } else {
            if s.id == registry.activeId { parts.append("In use now") }
            if s.borrowing {
                parts.append("Just borrowing")
            } else if GarageLearning.isLearning(ridesOnScooter: rides[s.id] ?? 0, borrowing: false) {
                parts.append("Learning \u{00B7} \(rides[s.id] ?? 0) of \(GarageLearning.rides) rides")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func load() {
        guard let db = AppModel.shared.database else { return }
        registry = GarageService.registry(db)
        rides = Dictionary(uniqueKeysWithValues: registry.scooters.map { ($0.id, GarageService.rideCount($0.id, db)) })
    }
}

/// N11-2: one scooter: name, Just borrowing, its service book, and leaving the Garage
struct GarageScooterView: View {
    let scooterId: String
    @State private var scooter: GarageScooter?
    @State private var name = ""
    @State private var confirm: GarageStatus?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let s = scooter {
                Section {
                    LabeledContent("Model", value: s.model)
                    if !s.status.isRetired {
                        TextField("Name (optional)", text: $name).onSubmit(saveName)
                        Toggle("Just borrowing", isOn: Binding(get: { scooter?.borrowing ?? false }, set: setBorrowing))
                    } else if let label = s.status.label {
                        LabeledContent("Status", value: label)
                    }
                } footer: {
                    if !s.status.isRetired { Text("A borrowed scooter's rides are kept. It gets no maintenance alerts.") }
                }
                Section {
                    NavigationLink("Service book") { MaintenanceHistoryView(scooterId: s.id).navigationTitle("Service book") }
                }
                if !s.status.isRetired {
                    Section {
                        Button("Sold it") { confirm = .sold }
                        Button("Lost it") { confirm = .lost }
                        Button("Remove", role: .destructive) { confirm = .removed }
                    } footer: {
                        Text("Its rides and service book stay on the phone.")
                    }
                }
            }
        }
        .navigationTitle(scooter?.displayName ?? "Scooter")
        .onAppear(perform: load)
        .onDisappear(perform: saveName)
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == .removed ? "Remove" : "Confirm", role: confirm == .removed ? .destructive : nil) { if let c = confirm { leave(c) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch confirm {
        case .sold: return "Mark it as sold?"
        case .lost: return "Mark it as lost?"
        default: return "Remove this scooter?"
        }
    }

    private var message: String {
        switch confirm {
        case .removed: return "Back up first: Settings \u{2192} Export everything. The app stops connecting to it; its rides stay."
        default: return "The app stops connecting to it. Its rides stay, and you can still export its service book."
        }
    }

    private func load() {
        guard let db = AppModel.shared.database else { return }
        scooter = GarageService.registry(db).scooter(scooterId)
        name = scooter?.name ?? ""
    }

    private func saveName() {
        guard let db = AppModel.shared.database, let s = scooter, !s.status.isRetired, (s.name ?? "") != name else { return }
        GarageService.rename(scooterId, name, db)
        // the Scooter tab's name is the active scooter's (the same app-only name)
        if GarageService.activeId(db) == scooterId {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { SettingsValue.clear(db, ScooterTabView.nameKey) } else { SettingsValue.set(db, ScooterTabView.nameKey, String(t.prefix(24))) }
        } else {
            SettingsValue.set(db, GarageSwap.parked(ScooterTabView.nameKey, scooterId), String(name.prefix(24)))
        }
        load()
    }

    private func setBorrowing(_ on: Bool) {
        guard let db = AppModel.shared.database else { return }
        GarageService.setBorrowing(scooterId, on, db)
        load()
    }

    private func leave(_ status: GarageStatus) {
        guard let db = AppModel.shared.database else { return }
        GarageService.retire(scooterId, as: status, db)
        let next = GarageService.registry(db).inUse.isEmpty ? nil : GarageService.activeId(db)
        AppModel.shared.scooter.retire(scooterId, next: next == scooterId ? nil : next)
        if next == nil || next == scooterId { ScooterRecord.forgetPairing(in: db) }
        confirm = nil
        dismiss()
    }
}

/// N11-2: Add another scooter: look for one that is not in the Garage yet, show it, then Add (or Just borrowing) / Cancel.
struct AddScooterSheet: View {
    private let link = AppModel.shared.scooter
    @State private var startedAt = Date()
    @State private var done = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "scooter").font(.system(size: 44)).foregroundStyle(Theme.accentInk).accessibilityHidden(true)
                if link.pairingPending {
                    Text(KnownScooters.foundText(model: link.foundModel ?? "Scooter", odometerKm: link.frame?.odometerKm, batteryPct: link.frame?.batteryPct))
                        .font(.headline).multilineTextAlignment(.center)
                    Button { add(borrowing: false) } label: {
                        Text("Add to my Garage").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Just borrowing") { add(borrowing: true) }
                } else {
                    Text("Switch on the other scooter and keep it close.").font(.headline).multilineTextAlignment(.center)
                    TimelineView(.periodic(from: .now, by: 5)) { t in
                        if t.date.timeIntervalSince(startedAt) > 30 {
                            Text("Can't find it yet. The app finds RND scooters (G100, G500).").font(.subheadline)
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Add a scooter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { startedAt = Date(); link.startAdding() }
        .onDisappear { if !done { link.cancelPairing() } }
        .presentationDetents([.medium])
    }

    private func add(borrowing: Bool) {
        if borrowing, let id = link.pendingPeripheralID { GarageService.pendingBorrowId = id }
        link.confirmPairing()
        done = true
        dismiss()
    }
}
