import SwiftUI

/// Developer → Crash catcher (d4, d5, d6) and the error log.
struct CrashView: View {
    private let catcher = CrashCatcher.shared
    private let results = CheckResults.shared
    @State private var lines: [String] = []

    var body: some View {
        List {
            Section {
                Text(catcher.lastRunCrashed ? "⚠️ The last session ended unexpectedly" : "The last session ended normally")
                row("d4")
                Button("Crash the app now", role: .destructive) { catcher.crashForTest() }
            } header: {
                Text("Our own catcher")
            } footer: {
                Text("Then open the app again: d4 should pass. iOS delivers its own report (d5) up to a day later.")
            }
            Section("iOS crash reports (MetricKit)") {
                row("d5")
                if catcher.metricKitReports.isEmpty {
                    Text("None received yet.").foregroundStyle(.secondary)
                }
                ForEach(catcher.metricKitReports, id: \.self) { Text($0).font(.footnote.monospaced()) }
            }
            Section("Error log") {
                row("d6")
                Button("Write a test entry") { writeTestEntry() }
                ForEach(Array(lines.suffix(100).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Crash catcher")
        .screen("Crash catcher")
        .onAppear { lines = ErrorLog.shared.lines() }
    }

    private func writeTestEntry() {
        let marker = "Test entry \(UUID().uuidString.prefix(8))"
        Log.info(source: "developer", marker)
        lines = ErrorLog.shared.lines()
        let stored = AppModel.shared.database != nil
        let found = lines.contains { $0.hasSuffix(marker) }
        results.set("d6", found && stored ? .pass : .fail,
                    found && stored ? "Stored in the database and read back" : "Not found in the database log")
    }

    private func row(_ id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(results.status(id).icon)
            VStack(alignment: .leading) {
                Text(CheckList.item(id)?.title ?? id)
                if !results.note(id).isEmpty {
                    Text(results.note(id)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
