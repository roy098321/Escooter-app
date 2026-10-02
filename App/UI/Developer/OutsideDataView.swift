import SwiftUI

/// Developer → Outside data (e1–e7): fetch and parse every outside source once.
struct OutsideDataView: View {
    private let probes = OutsideProbes.shared
    private let results = CheckResults.shared

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
                Text("Needs internet. Only a location rounded to ~2 km is sent; with no location yet, a fixed point in the ocean is used. A failure shows the fallback the app will use.")
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
    }
}
