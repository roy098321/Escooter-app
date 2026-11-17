import CorckieCore
import SwiftUI
import UniformTypeIdentifiers

/// N6-7 (batch 6): Settings → Data & backup → Backup. Where backups go (a folder the rider picks, e.g. iCloud Drive, else this
/// iPhone), when the last one was written, and a quiet note when the picked folder is gone. Backups run by themselves after
/// every ride and weekly; "Back up now" writes a full one. The test rows (d2, d3, d9) stay in Developer → Backup folder.
struct BackupSettingsView: View {
    private let folder = BackupFolder.shared
    private let writer = BackupWriter.shared
    @State private var picking = false

    var body: some View {
        List {
            Section {
                LabeledContent("Folder", value: folder.label)
                LabeledContent("Last backup", value: BackupPlan.lastBackupText(
                    lastMs: writer.lastBackupMs, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                    utcOffsetMin: TimeZone.current.secondsFromGMT() / 60))
                if let note = folder.fallbackNote {
                    Label(note, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("A backup is written after every ride and a full one every week. In iCloud Drive it is safe if the phone is lost.")
            }
                .glassRows()
            Section {
                Button(folder.hasFolder ? "Choose another folder\u{2026}" : "Choose a folder\u{2026}") { picking = true }
                Button("Back up now") { writer.backUpNow() }
            }
                .glassRows()
        }
            .glassList()
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Backup")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                folder.remember(url)
                writer.backUpNow()
            case .failure(let error):
                Log.error(source: "backup", "Pick failed: \(error.localizedDescription)")
            }
        }
    }
}
