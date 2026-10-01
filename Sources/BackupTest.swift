import SwiftUI
import UniformTypeIdentifiers

// D08: can a sideloaded app keep writing to a folder the user picked once?
struct BackupTestView: View {
    @AppStorage("backupBookmark") private var bookmark = Data()
    @State private var picking = false
    @State private var log: [String] = []

    var body: some View {
        List {
            Section {
                Text("Pick a folder once (e.g. iCloud Drive › Scooter), then write a file. Repeat the write after restarting the phone.")
                    .font(.footnote)
            }
            Section {
                Button("Pick folder") { picking = true }
                Button("Write test file") { write() }
                    .disabled(bookmark.isEmpty)
            }
            Section("Log") {
                ForEach(log.indices.reversed(), id: \.self) { i in
                    Text(log[i]).font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle("Backup folder")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    bookmark = try url.bookmarkData()
                    add("Folder saved: \(url.lastPathComponent)")
                } catch {
                    add("❌ Couldn't remember the folder: \(error.localizedDescription)")
                }
            case .failure(let error):
                add("❌ Pick failed: \(error.localizedDescription)")
            }
        }
    }

    private func write() {
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            let file = folder.appendingPathComponent("p2-lab-test.txt")
            let text = "P2 Lab backup test · \(Date.now.formatted())\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            let back = try String(contentsOf: file, encoding: .utf8)
            add(back == text
                ? "✅ Wrote and read back \(file.lastPathComponent)\(stale ? " (folder link was refreshed)" : "")"
                : "⚠️ The file read back differently")
        } catch {
            add("❌ \(error.localizedDescription)")
        }
    }

    private func add(_ line: String) {
        log.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(line)")
    }
}
