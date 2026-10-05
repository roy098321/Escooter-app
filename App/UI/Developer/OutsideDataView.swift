import SwiftUI

/// Developer → Outside data (e1–e7): fetch and parse every outside source once.
struct OutsideDataView: View {
    private let probes = OutsideProbes.shared
    private let results = CheckResults.shared
    @State private var cache = OutsideCacheSummary.text(AppModel.shared.database)
    @State private var refreshing = false
    @State private var lastRun = OutsideDataService.shared.lastRun.text

    var body: some View {
        List {
            Section {
                Button {
                    Task { await probes.runAll() }
                } label: {
                    if probes.running {
                        HStack {
                            ProgressView()
                            Text("Running…")
                        }
                    } else {
                        Label("Run all", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(probes.running)
            } footer: {
                Text("Needs internet. Only a location rounded to ~1 km is sent; with no location yet, a fixed point in the ocean is used. A failure shows the fallback the app will use.")
            }
            Section {
                Text(cache)
                Text(lastRun).font(.footnote).foregroundStyle(.secondary)
                Button {
                    guard let db = AppModel.shared.database, !refreshing else { return }
                    refreshing = true
                    Task {
                        lastRun = await OutsideDataService.shared.runNow(database: db, reason: "developer")
                        cache = OutsideCacheSummary.text(db)
                        refreshing = false
                    }
                } label: {
                    if refreshing {
                        HStack {
                            ProgressView()
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh the cache now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(refreshing)
            } header: {
                Text("Cache (M4-01)")
            } footer: {
                Text("Filled by itself at app open and after every ride: holidays, the forecast for your ~1 km cell, weather history for past rides, map elevation. Offline it uses what is cached.")
            }
            Section("Sources") {
                ForEach(CheckList.all.filter { $0.group == CheckList.outside }) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(results.status(item.id).icon)
                            Text("\(item.id.uppercased()) · \(item.title)")
                        }
                        Text(probes.lines[item.id]?.text ?? (results.note(item.id).isEmpty ? item.expected : results.note(item.id)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Attribution") {
                Text("Weather: Open-Meteo.com (CC BY 4.0) and MET Norway (CC BY 4.0) · Holidays: Hebcal (CC BY 4.0) · Fuel price: Israel Ministry of Energy · Map tiles: © OpenStreetMap contributors © CARTO")
                    .font(.footnote)
            }
        }
        .navigationTitle("Outside data")
        .screen("Outside data")
    }
}
