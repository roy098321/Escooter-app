import SwiftUI

/// Settings → Report a problem (M1-11, C28b): the same one-file export as Developer → Results, one tap away.
struct ReportProblemView: View {
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var messages: [(id: Int64, type: String, sentAt: Int64)] = []

    var body: some View {
        List {
            if !messages.isEmpty {
                Section("Were these messages right?") {
                    ForEach(messages, id: \.id) { m in
                        ThumbsRow(kind: "message", subjectId: String(m.id), subjectText: m.type,
                                  label: "\(m.type) · \(Date(timeIntervalSince1970: Double(m.sentAt) / 1000).formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                    .glassRows()
            }
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
                Text("One .zip with the last 15 minutes of logs, the error log, Bluetooth events, check results, your ride notes and thumbs. It stays on your phone until you share it.")
            }
                .glassRows()
        }
            .glassList()
        .onAppear {
            if let db = AppModel.shared.displayDatabase { messages = (try? FieldKitQueries(db).recentSentMessages()) ?? [] }
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
