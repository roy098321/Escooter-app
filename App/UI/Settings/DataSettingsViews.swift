import CorckieCore
import CorckieSim
import SwiftUI
import UniformTypeIdentifiers

// M5-05 / M5-07: Settings → Data and backup. Export everything (one JSON file), Restore (merge by ride) and Delete all data.

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Export everything: one JSON file with every ride (all readings), places, routes, charges, calibration, maintenance and settings.
struct ExportEverythingView: View {
    /// ui-shot only: the empty state
    var previewEmpty = false
    @State private var rideCount: Int?
    @State private var working = false
    @State private var summary = ""
    @State private var share: ShareFile?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                if previewEmpty || rideCount == 0 {
                    Label("No rides yet", systemImage: "tray").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("One file with everything. Restore reads it back.")
                    .font(.subheadline)
                Button {
                    Task { await make() }
                } label: {
                    HStack {
                        Text(working ? "Making the file\u{2026}" : "Make the file")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working)
            } footer: {
                if !summary.isEmpty { Text(summary) }
            }
                .glassRows()
        }
            .glassList()
        .navigationTitle("Export everything")
        .onAppear {
            guard !previewEmpty, let db = AppModel.shared.displayDatabase else { return }
            rideCount = (try? RideQueries(db).rides())?.count
        }
        .sheet(item: $share) { item in ShareSheet(url: item.url) }
        .alert("Could not export", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .screen("Export everything")
    }

    private func make() async {
        guard let db = AppModel.shared.database else { return }
        working = true
        defer { working = false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = TimeZone.current.secondsFromGMT() / 60
        let build = AppInfo.build
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(ExportAll.fileName(nowMs: now, utcOffsetMin: offset))
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ExportAll.write(db, to: url, build: build, nowMs: now)
            }.value
            summary = "\(result.rides) rides, " + String(format: "%.1f MB", Double(result.bytes) / 1_000_000)
            share = ShareFile(url: url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Restore from a file or from the backup folder. Merges by ride: nothing already on the phone is lost or doubled.
struct RestoreView: View {
    @State private var picking = false
    @State private var working = false
    @State private var result = ""
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Button("Restore from a file\u{2026}") { picking = true }.disabled(working)
                if BackupFolder.shared.hasFolder {
                    Button("Restore from the backup folder") { Task { await fromFolder() } }.disabled(working)
                }
            } header: {
                Text("Restore").textCase(nil)
            } footer: {
                Text("Rides already here are skipped.")
            }
                .glassRows()
            if working {
                Section { HStack { Text("Restoring\u{2026}"); Spacer(); ProgressView() } }
                    .glassRows()
            }
            if !result.isEmpty {
                GlassSection("Result") { Text(result) }
                    .glassRows()
            }
        }
            .glassList()
        .navigationTitle("Restore")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data, .item], allowsMultipleSelection: true) { outcome in
            if case .success(let urls) = outcome { Task { await restore(urls) } }
        }
        .alert("Could not restore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .screen("Restore")
    }

    private func restore(_ urls: [URL]) async {
        guard let db = AppModel.shared.database else { return }
        working = true
        defer { working = false }
        var total = RestoreReport()
        var failures: [String] = []
        for url in urls {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            do {
                let one = try await Task.detached(priority: .userInitiated) { try RestoreService.restore(db, from: url) }.value
                total.ridesAdded += one.ridesAdded
                total.ridesSkipped += one.ridesSkipped
                total.ridesFailed += one.ridesFailed
                total.otherRows += one.otherRows
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        result = total.text + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
        if total.ridesAdded == 0 && !failures.isEmpty { errorText = failures.joined(separator: "\n") }
    }

    private func fromFolder() async {
        guard let db = AppModel.shared.database else { return }
        working = true
        defer { working = false }
        do {
            let report = try BackupFolder.shared.withFolder { root in try RestoreService.restoreFolder(db, root: root) }
            result = report.text
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Import ride logs: rides recorded before 1.0 (a 0.4 c8 set, or an nRF Connect log with Sensor Logger files) replayed through the real
/// recorder into the real database as normal rides. Importing the same files twice adds nothing.
struct ImportRideLogsView: View {
    @State private var picking = false
    @State private var working = false
    @State private var result = ""
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Button("Pick log files\u{2026}") { picking = true }.disabled(working)
            } header: {
                Text("Import ride logs").textCase(nil)
            } footer: {
                Text("Pick the .csv or .txt files of one or more rides together. Rides already here are skipped.")
            }
                .glassRows()
            if working {
                Section { HStack { Text("Importing\u{2026}"); Spacer(); ProgressView() } }
                    .glassRows()
            }
            if !result.isEmpty {
                GlassSection("Result") { Text(result) }
                    .glassRows()
            }
        }
            .glassList()
        .navigationTitle("Import ride logs")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text], allowsMultipleSelection: true) { outcome in
            if case .success(let urls) = outcome { Task { await run(urls) } }
        }
        .alert("Could not import", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .screen("Import ride logs")
    }

    private func run(_ urls: [URL]) async {
        guard let db = AppModel.shared.database else { return }
        working = true
        defer { working = false }
        var files: [ImportFileText] = []
        for url in urls {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append(ImportFileText(name: url.lastPathComponent, text: String(decoding: data, as: UTF8.self), modified: modified))
        }
        let build = AppInfo.build
        let picked = files
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try await RideLogImporter.run(db, files: picked, build: build)
            }.value
            result = report.text
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// SE4: the raw-data setting and Import ride logs, in Settings → Developer
struct DeveloperDataRows: View {
    @State private var retention = RawRetention.default
    @State private var usage = "\u{2013}"

    var body: some View {
        Group {
            SegmentedRow(title: "Keep raw data", options: RawRetention.allCases.map { ($0, $0.rawValue) }, selection: $retention)
                .onChange(of: retention) { _, v in
                    guard let db = AppModel.shared.database else { return }
                    RetentionService.set(db, v)
                    refreshUsage()
                }
            LabeledContent("Raw data on this phone", value: usage).font(.footnote)
            NavigationLink {
                ImportRideLogsView()
            } label: {
                Label("Import ride logs", systemImage: "square.and.arrow.down.on.square")
            }
        }
        .onAppear {
            guard let db = AppModel.shared.database else { return }
            retention = RetentionService.current(db)
            refreshUsage()
        }
    }

    private func refreshUsage() {
        guard let db = AppModel.shared.database else { return }
        let u = RetentionService.usage(db)
        usage = u.chunks == 0 ? "none" : "\(u.chunks) chunks, " + String(format: "%.1f MB", Double(u.bytes) / 1_000_000)
    }
}

/// Settings → Data & backup, as rows of the Settings list (the caller puts them in a Section).
struct DataSettingsRows: View {
    @State private var confirmDelete = false
    @State private var errorText: String?

    var body: some View {
        Group {
            NavigationLink {
                ExportEverythingView()
            } label: {
                Label("Export everything", systemImage: "square.and.arrow.up")
            }
            NavigationLink {
                RestoreView()
            } label: {
                Label("Restore", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete all data", systemImage: "trash") }
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all data", role: .destructive) { deleteAll() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("All rides, routes, places, charges and insights are removed from this phone. Settings and the scooter pairing stay. Backup files are not touched, so Restore brings everything back. This cannot be undone.")
        }
        .alert("Could not delete", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func deleteAll() {
        guard let db = AppModel.shared.database else { return }
        do {
            try DeleteAllData.run(db)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
