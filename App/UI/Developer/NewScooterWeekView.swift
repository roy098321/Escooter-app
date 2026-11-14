import CorckieCore
import GRDB
import SwiftUI

/// D2 option C: Developer → New scooter week. Milestones tick by themselves after Start fresh; each has an optional note line.
/// No thumbs, nothing on rider screens (P-10). Everything stays on the phone; the week report is shared by the owner by hand.
enum NewScooterWeekStore {
    static let sharedKey = "fresh.weekSharedAtMs"
    static func noteKey(_ id: String) -> String { "fresh.note.\(id)" }

    static func isActive(_ db: AppDatabase?) -> Bool {
        let started = SettingsValue.number(db, StartFresh.startedKey).map { Int64($0) }
        let shared = SettingsValue.number(db, sharedKey).map { Int64($0) }
        return NewScooterWeek.isActive(startedAtMs: started, sharedAtMs: shared, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func facts(_ db: AppDatabase) -> NewScooterWeek.Facts {
        var f = NewScooterWeek.Facts()
        let started = Int64(SettingsValue.number(db, StartFresh.startedKey) ?? 0)
        f.startedFresh = started > 0
        f.backupMade = StartFresh.latestBackup(db) != nil
        f.riderInfoBack = SettingsValue.number(db, StartFresh.broughtBackKey) != nil
        try? db.writer.read { d in
            f.paired = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM scooter WHERE forgottenAt IS NULL") ?? 0) > 0
            f.rides = try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM ride WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = 0
                AND startAt >= ? AND \(BatteryDoor.rides())
                """, arguments: [started]) ?? 0
            f.routeSuggested = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM route WHERE COALESCE(createdAt, 0) >= ?", arguments: [started]) ?? 0) > 0
            f.bestRouteRides = try Int.fetchOne(d, sql: """
                SELECT COALESCE(MAX(c), 0) FROM (SELECT COUNT(*) AS c FROM ride WHERE routeId IS NOT NULL AND startAt >= ? AND \(BatteryDoor.rides()) GROUP BY routeId)
                """, arguments: [started]) ?? 0
            f.calibrated = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM calibration WHERE status = 'calibrated'") ?? 0) > 0
            f.weeklySummarySeen = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM week_summary WHERE COALESCE(notifiedAt, 0) >= ?", arguments: [started]) ?? 0) > 0
        }
        return f
    }

    static func note(_ db: AppDatabase, _ id: String) -> String {
        let value: String? = try? db.writer.read { try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = ?", arguments: [noteKey(id)]) }
        return value ?? ""
    }
}

struct NewScooterWeekView: View {
    @State private var facts = NewScooterWeek.Facts()
    @State private var notes: [String: String] = [:]
    @State private var loaded = false

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            ForEach(NewScooterWeek.milestones, id: \.id) { m in
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NewScooterWeek.isDone(m.id, facts) ? "\u{2705}" : "\u{23F3}")
                        Text("\(m.id) \u{00B7} \(m.title)").font(.subheadline.weight(.semibold))
                    }
                    Text(m.lookAt).font(.footnote).foregroundStyle(.secondary)
                    TextField("Note (optional)", text: Binding(
                        get: { notes[m.id] ?? "" },
                        set: { value in
                            notes[m.id] = value
                            SettingsValue.set(db, NewScooterWeekStore.noteKey(m.id), value)
                        }))
                        .font(.footnote)
                }
                .glassRows()
            }
            Section {
                ShareLink(item: NewScooterWeek.report(facts, notes: notes)) {
                    Label("Share week report", systemImage: "square.and.arrow.up")
                }
                Button("Hide this group") {
                    SettingsValue.set(db, NewScooterWeekStore.sharedKey, String(Int64(Date().timeIntervalSince1970 * 1000)))
                }
            } footer: {
                Text("Share the report first. Hiding removes this group from Developer.")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("New scooter week")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let db, !loaded else { return }
            loaded = true
            facts = NewScooterWeekStore.facts(db)
            for m in NewScooterWeek.milestones { notes[m.id] = NewScooterWeekStore.note(db, m.id) }
        }
        .screen("New scooter week")
    }
}
