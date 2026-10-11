import CorckieCore
import SwiftUI

/// M5-04: Ride Replay in the app (a web view with the replay page, tiles from the cache or the network) and the download of the
/// same page as ONE self-contained HTML file (tiles embedded; offline with nothing cached the file still plays, without a map).
struct ReplayView: View {
    var rideId: String?
    /// ui-shot only: made-up data and no network
    var previewData: ReplayData?
    var startDownload = false

    @Environment(\.dismiss) private var dismiss
    @State private var ride: ReplayRide?
    @State private var missing = false
    @State private var html = ""
    @State private var state = ""
    @State private var building = false
    @State private var buildText = ""
    @State private var shareItem: ShareFile?
    @State private var errorText: String?

    struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Group {
            if !html.isEmpty {
                ReplayWebView(html: html, onState: stateHandler)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .topTrailing) {
                        if previewData != nil, !state.isEmpty {
                            Text(state).font(.caption2.monospaced()).padding(4).background(.thinMaterial).padding(6)
                        }
                    }
            } else if missing {
                ContentUnavailableView("No replay", systemImage: "play.slash",
                                       description: Text("This ride has too few readings to replay."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Ride Replay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                if building {
                    ProgressView()
                } else {
                    Button { Task { await download() } } label: { Label("Download", systemImage: "square.and.arrow.down") }
                        .disabled(ride == nil && previewData == nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if building || !buildText.isEmpty {
                Text(building ? "Getting the map\u{2026} \(buildText)" : buildText)
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.thinMaterial)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url).v1Label()
        }
        .alert("Could not make the file", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: load)
        .screen("Ride Replay")
    }

    private var stateHandler: ((String) -> Void)? {
        if previewData == nil { return nil }
        return { text in state = text }
    }

    private func load() {
        guard html.isEmpty else { return }
        if let previewData {
            ride = ReplayRide(data: previewData, fileName: "Ride Replay \u{2013} Sample.html")
            html = ReplayHTML.build(previewData, colourBlind: DisplaySettings.colourBlind, highContrast: SunlightMonitor.shared.on) { _ in nil }
            return
        }
        guard let id = rideId, let db = AppModel.shared.displayDatabase, let loaded = ReplayDataLoader.load(db, rideId: id) else {
            missing = true
            return
        }
        ride = loaded
        html = ReplayHTML.build(loaded.data, colourBlind: DisplaySettings.colourBlind, highContrast: SunlightMonitor.shared.on) { ReplaySchemeHandler.href($0) }
        if startDownload { Task { await download() } }
    }

    /// One HTML file: the page with its tiles as data addresses
    private func download() async {
        guard let ride, !building else { return }
        building = true
        buildText = ""
        defer { building = false }
        let tiles = previewData != nil ? [] : ReplayBuilder.tiles(for: ride.data)
        let got = await TileCache.shared.fetchAll(tiles) { done, total in
            DispatchQueue.main.async { buildText = "\(done) of \(total)" }
        }
        let page = ReplayHTML.build(ride.data, colourBlind: DisplaySettings.colourBlind) { tile in
            got[tile].map { "data:image/png;base64," + $0.base64EncodedString() }
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayShare", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(ride.fileName)
            try page.write(to: url, atomically: true, encoding: .utf8)
            let mb = String(format: "%.1f MB", Double(page.utf8.count) / 1_000_000)
            let missingTiles = tiles.count - got.count
            buildText = missingTiles > 0 ? "File ready (\(mb)). \(missingTiles) of \(tiles.count) map tiles could not be loaded (offline?), the file still plays."
                                         : "File ready (\(mb))."
            shareItem = ShareFile(url: url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// The iPhone share sheet for a file (Files, AirDrop, WhatsApp, mail)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
