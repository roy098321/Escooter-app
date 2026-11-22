import CorckieCore
import SwiftUI

/// Hotfix 110.221126.01 (owner 22 Nov, option A; mock reports/maintenance/mock/tile-opens-part-A.png): a part tile (Scooter tab) or a
/// part row (Maintenance screen) opens that part's own page directly: one tap, one screen, Back returns. Nothing pops up on top.
/// A part with an issue: what was found, your last rides vs your normal, what to do, Export a report, I fixed it, Checked it's fine.
/// A quiet part: the next check in km, its reminder (editable or off), "Nothing found so far" or learning, Log what I did.
struct PartPageView: View {
    let part: MaintPart

    @State private var row: PartRow?
    @State private var fault: FaultRecord?
    @State private var reminder: MaintenanceService.Row?
    @State private var remindOn = true
    @State private var km = 300.0
    @State private var exporting: FaultRecord?
    @State private var logging = false

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            if let f = fault {
                let t = FaultCopy.text(f.kind)
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.kind.level == .red ? "Not safe to ride" : "Needs a look")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(f.kind.level == .red ? FaultPopupView.red : Theme.accentInk)
                        Text(t.row).font(.headline)
                        Text("Found " + HistoryDates.dayMonth(f.day) + (f.odoKm.map { " \u{00B7} \(Int($0.rounded()).formatted()) km" } ?? ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(t.found).font(.subheadline)
                    FaultNormalChart(record: f)
                }
                Section("What to do") { Text(t.what) }
                Section {
                    Button { exporting = f } label: { Label(FaultCopy.exportReport, systemImage: "square.and.arrow.up") }
                    Button(FaultCopy.fixedIt) { FaultStore.fixed(f.id, db); reload() }
                    Button(FaultCopy.checkedFine) { FaultStore.checkedFine(f.id, db); reload() }
                } footer: {
                    Text("\"Checked, it's fine\" makes the app less sensitive to this. Twice, and it stays quiet.")
                }
            } else if let row {
                Section {
                    Text(row.line).font(.headline)
                    if case .learning = row.state {
                        Text("The app learns your scooter first, so it never warns on a guess.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("The app watches the \(part.title.lowercased()) on every ride.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let r = reminder {
                Section {
                    Text(r.item.hint)
                    LabeledContent("Status", value: Maintenance.statusText(r.status))
                    Toggle("Remind me", isOn: $remindOn)
                    if remindOn { Stepper("Every \(Int(km)) km", value: $km, in: 50...5000, step: 50) }
                    Button("Mark done") {
                        if let db { MaintenanceService.markDone(id: r.id, db) }
                        reload()
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    Text("Until your scooter's manual is read, these distances are a starting guess.")
                }
            }
            Section {
                Button { logging = true } label: { Label("Log what I did", systemImage: "wrench.adjustable") }
            }
        }
        .navigationTitle(part.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $logging, onDismiss: reload) { LogWorkSheet() }
        .mechanicExport($exporting)
        .onAppear(perform: reload)
        .onDisappear(perform: saveInterval)
    }

    private func reload() {
        guard let db else { return }
        let parts = MaintenanceService.parts(db)
        row = parts.first { $0.part == part }
        if case .issue(_, let id)? = row?.state {
            fault = FaultStore.records(db).first { $0.id == id }
        } else {
            fault = nil
        }
        if let rid = row?.reminderId {
            reminder = MaintenanceService.rows(db).first { $0.id == rid }
            remindOn = reminder?.item.intervalKm != nil
            km = reminder?.item.intervalKm ?? Maintenance.defaults(odoKm: nil, nowMs: 0).first { $0.id == rid }?.intervalKm ?? 300
        } else {
            reminder = nil
        }
        FaultCenter.shared.reload(db)
    }

    private func saveInterval() {
        guard let db, let r = reminder else { return }
        let new: Double? = remindOn ? km : nil
        if new != r.item.intervalKm { MaintenanceService.setInterval(id: r.id, km: new, db) }
    }
}
