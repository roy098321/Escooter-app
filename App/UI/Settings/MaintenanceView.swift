import CorckieCore
import SwiftUI

/// M3-06: Settings → Maintenance. Tyres (50 PSI), brakes, bolts: km left, "Mark done" restarts the count.
/// The Scooter tab (M3-05) will link here too.
struct MaintenanceView: View {
    @State private var rows: [MaintenanceService.Row] = []

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.item.name).font(.headline)
                            Spacer()
                            Text(Maintenance.statusText(row.status))
                                .font(.subheadline)
                                .foregroundStyle(row.status.isDue ? Color.orange : Color.secondary)
                        }
                        Text(row.item.hint).font(.footnote).foregroundStyle(.secondary)
                        Button("Mark done") {
                            if let db = AppModel.shared.database { MaintenanceService.markDone(id: row.id, db) }
                            reload()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            }
                .glassRows()
        }
            .glassList()
        .navigationTitle("Maintenance")
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let db = AppModel.shared.database else { return }
        rows = MaintenanceService.rows(db)
    }
}
