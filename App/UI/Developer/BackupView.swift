import SwiftUI
import UniformTypeIdentifiers

/// Developer → Backup folder (d2, d3): pick a folder once, write a test file; again after a restart.
struct BackupView: View {
    private let backup = BackupFolder.shared
    private let results = CheckResults.shared
    @State private var picking = false

    var body: some View {
        List {
            Section {
                Text("Pick a folder once (e.g. iCloud Drive › CorckieApp), then Write test file. Restart the phone and write again.")
                    .font(.footnote)
                row("d2")
                row("d3")
            }
            Section {
                LabeledContent("Folder", value: backup.folderName ?? "not picked")
                Button("Pick folder") { picking = true }
                Button("Write test file") { backup.writeTestFile() }
                    .disabled(!backup.hasFolder)
            }
            Section("Log") {
                ForEach(Array(backup.log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle("Backup folder")
        .screen("Backup folder")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): backup.remember(url)
            case .failure(let error): Log.error(source: "backup", "Pick failed: \(error.localizedDescription)")
            }
        }
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
