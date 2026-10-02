import SwiftUI

/// Settings → Developer → Results: the summary and ONE export for Claude.
struct ResultsView: View {
    private let results = CheckResults.shared
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                CountsRow()
            }
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share export (\(exportURL.lastPathComponent))", systemImage: "square.and.arrow.up")
                    }
                    Button("Make a fresh export") { makeExport() }
                } else {
                    Button {
                        makeExport()
                    } label: {
                        Label("Prepare export for Claude", systemImage: "doc.zipper")
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("One .zip with the check results, error log, Bluetooth events, raw scooter packets, sensors and outside-data results. Send it to Claude.")
            }
            Section("Summary") {
                Text(results.report())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Results")
    }

    private func makeExport() {
        do {
            exportURL = try Exporter.makeExport()
            error = nil
        } catch {
            self.error = "Export failed: \(error.localizedDescription)"
            Log.error(source: "export", error.localizedDescription)
        }
    }
}
