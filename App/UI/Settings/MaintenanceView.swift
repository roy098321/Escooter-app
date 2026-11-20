import CorckieCore
import SwiftUI

/// N10-13 (batch 10): the Maintenance screen (mock reports/maintenance/mock/screen3.png v4), replacing the M3-06 list.
/// "Is my scooter OK, and what needs doing?" Header (model · km); ONE list, a row per part; a part with an issue leaves the list
/// into its own card at the top (light-orange fill, orange border, solid icon tile, bold line, "!" badge; red when it isn't safe
/// to ride); quiet rows show the next check in km; learning rows are faded. Never "OK", never a green tick.
/// Tap: a fault → its page; a reminder → its page (interval editable or off); Battery → the one Battery page (N10-21).
/// One button: Log what I did.
struct MaintenanceView: View {
    /// N10-21: open straight on a part (from a Scooter tab tile)
    var focus: MaintPart?

    @State private var rows: [PartRow] = []
    @State private var header = ""
    @State private var fault: FaultRecord?
    @State private var reminder: ReminderTarget?
    @State private var logging = false
    @State private var battery = false
    @State private var focused = false

    struct ReminderTarget: Identifiable { let id: String }

    static let orange = Theme.accent
    static let red = Color(hex: "#C81E1E")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(header)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(rows.filter(\.standsOut)) { row in
                    Button { open(row) } label: { IssueCard(row: row) }
                        .buttonStyle(.plain)
                }
                VStack(spacing: 0) {
                    let quiet = rows.filter { !$0.standsOut }
                    ForEach(Array(quiet.enumerated()), id: \.element.id) { i, row in
                        Button { open(row) } label: { PartListRow(row: row) }
                            .buttonStyle(.plain)
                        if i < quiet.count - 1 { Divider().padding(.leading, 72) }
                    }
                }
                .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                Button { logging = true } label: {
                    Label("Log what I did", systemImage: "wrench.adjustable")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, 24)
        }
        .navigationTitle("Maintenance")
        .toolbar {
            // N10-14: History = the clock button top right
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { MaintenanceHistoryView() } label: {
                    Image(systemName: "clock.arrow.circlepath").accessibilityLabel("History")
                }
            }
        }
        .navigationDestination(isPresented: $battery) { BatteryView() }
        .sheet(item: $fault) { r in FaultDetailSheet(record: r, onDone: reload) }
        .sheet(item: $reminder, onDismiss: reload) { t in ReminderSheet(reminderId: t.id) }
        .sheet(isPresented: $logging, onDismiss: reload) { LogWorkSheet() }
        .onAppear {
            reload()
            if let f = focus, !focused, let row = rows.first(where: { $0.part == f }) {
                focused = true
                open(row)
            }
        }
    }

    private func open(_ row: PartRow) {
        switch row.state {
        case .issue(_, let id):
            fault = FaultStore.records(AppModel.shared.database).first { $0.id == id }
        case .due(let id):
            reminder = ReminderTarget(id: id)
        default:
            if row.part == .battery { battery = true } else if let r = row.reminderId { reminder = ReminderTarget(id: r) }
        }
    }

    private func reload() {
        guard let db = AppModel.shared.database else { return }
        header = MaintenanceService.header(db)
        rows = MaintenanceService.parts(db)
        FaultCenter.shared.reload(db)
    }
}

/// The part icons (SF Symbols until the orange line icons of mock/icons.png are drawn as assets)
enum PartIcon {
    static func symbol(_ p: MaintPart) -> String {
        switch p {
        case .battery: return "battery.75percent"
        case .brakes: return "circle.circle"
        case .tyres: return "lifepreserver"
        case .motor: return "engine.combustion"
        case .bolts: return "wrench.adjustable"
        case .electrics: return "bolt"
        }
    }
}

/// A part with an issue or a due reminder: its own card at the top
private struct IssueCard: View {
    let row: PartRow
    private var tint: Color { row.isRed ? MaintenanceView.red : MaintenanceView.orange }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: PartIcon.symbol(row.part))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 52, height: 52)
                .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.part.title).font(.headline)
                Text(row.isRed ? "Not safe to ride \u{00B7} " + row.line : row.line)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 8)
            Text("!")
                .font(.headline.weight(.heavy))
                .frame(width: 30, height: 30)
                .background(tint, in: Circle())
                .foregroundStyle(.black.opacity(0.85))
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(tint, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Needs attention")
    }
}

/// A quiet or learning part in the plain list
private struct PartListRow: View {
    let row: PartRow
    private var learning: Bool { if case .learning = row.state { return true } else { return false } }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: PartIcon.symbol(row.part))
                .font(.title3)
                .foregroundStyle(learning ? Color.secondary : MaintenanceView.orange)
                .frame(width: 44, height: 44)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.part.title).font(.body)
                Text(row.line).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .opacity(learning ? 0.6 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A km reminder: every N km (editable) or off; Mark done restarts it
struct ReminderSheet: View {
    let reminderId: String
    @Environment(\.dismiss) private var dismiss
    @State private var row: MaintenanceService.Row?
    @State private var on = true
    @State private var km = 300.0

    var body: some View {
        NavigationStack {
            Form {
                if let row {
                    Section {
                        Text(row.item.hint)
                        LabeledContent("Status", value: Maintenance.statusText(row.status))
                    }
                    Section {
                        Toggle("Remind me", isOn: $on)
                        if on {
                            Stepper("Every \(Int(km)) km", value: $km, in: 50...5000, step: 50)
                        }
                    } footer: {
                        Text("Until your scooter's manual is read, these distances are a starting guess. One notification, never during a ride.")
                    }
                    Section {
                        Button("Mark done") {
                            if let db = AppModel.shared.database { MaintenanceService.markDone(id: reminderId, db) }
                            save()
                        }
                    }
                }
            }
            .navigationTitle(row?.item.name ?? "Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } } }
            .onAppear {
                guard let db = AppModel.shared.database else { return }
                row = MaintenanceService.rows(db).first { $0.id == reminderId }
                on = row?.item.intervalKm != nil
                km = row?.item.intervalKm ?? Maintenance.defaults(odoKm: nil, nowMs: 0).first { $0.id == reminderId }?.intervalKm ?? 300
            }
        }
    }

    private func save() {
        if let db = AppModel.shared.database { MaintenanceService.setInterval(id: reminderId, km: on ? km : nil, db) }
        dismiss()
    }
}

/// "Log what I did": a one-tap list; the km comes from the scooter
struct LogWorkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var odo: Double?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LogWhatIDid.allCases, id: \.self) { what in
                        Button {
                            if let db = AppModel.shared.database { MaintenanceService.log(what, db) }
                            dismiss()
                        } label: {
                            Label(what.title, systemImage: PartIcon.symbol(what.part))
                        }
                    }
                } footer: {
                    Text(odo.map { "One tap. The km comes from the scooter (\(Int($0.rounded()).formatted()) km)." } ?? "One tap. The km comes from the scooter.")
                }
            }
            .navigationTitle("Log what I did")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if let db = AppModel.shared.database { odo = (try? MaintenanceQueries(db).odometerKm()) ?? nil }
            }
        }
    }
}
