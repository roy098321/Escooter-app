import SwiftUI

/// Settings → Report a problem (M1-11, C28b): the same one-file export as Developer → Results, one tap away.
struct ReportProblemView: View {
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share report (\(exportURL.lastPathComponent))", systemImage: "square.and.arrow.up")
                    }
                    Button("Make a fresh report") { make() }
                } else {
                    Button {
                        make()
                    } label: {
                        Label("Prepare report", systemImage: "doc.zipper")
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("One .zip with the error log, Bluetooth events and check results. It stays on your phone until you share it.")
            }
        }
        .navigationTitle("Report a problem")
        .screen("Report a problem")
    }

    private func make() {
        do {
            exportURL = try Exporter.makeExport()
            error = nil
        } catch {
            self.error = "Report failed: \(error.localizedDescription)"
            Log.error(source: "export", error.localizedDescription)
        }
    }
}
