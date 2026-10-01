import SwiftUI
import UniformTypeIdentifiers
import WebKit

// D10: does the one-file Ride Replay run smoothly at 50× inside the app?
// The file is picked from Files, so no ride data ever goes into the repo.
struct ReplayTestView: View {
    @State private var picking = false
    @State private var fileURL: URL?
    @State private var message: String?

    var body: some View {
        Group {
            if let fileURL {
                WebView(url: fileURL).ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("Open a Ride Replay file", systemImage: "play.rectangle")
                } description: {
                    Text(message ?? "Pick the ride 2 replay (.html) from Files, then play it at 50×.")
                } actions: {
                    Button("Choose file") { picking = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Ride Replay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if fileURL != nil {
                Button("Other file") { picking = true }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.html]) { result in
            guard case .success(let source) = result else { return }
            let ok = source.startAccessingSecurityScopedResource()
            defer { if ok { source.stopAccessingSecurityScopedResource() } }
            let copy = URL.documentsDirectory.appendingPathComponent("replay-\(UUID().uuidString).html")
            do {
                try FileManager.default.copyItem(at: source, to: copy)
                fileURL = copy
            } catch {
                message = "Couldn't open the file: \(error.localizedDescription)"
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
