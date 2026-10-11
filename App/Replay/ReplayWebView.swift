import CorckieCore
import SwiftUI
import WebKit

/// M5-04: the in-app Ride Replay viewer. The same page as the downloaded file, but its map tiles come through the
/// `corckie-tile://t/<z>/<x>/<y>` address, which this handler serves from the disk cache first and from the network second.
final class ReplaySchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "corckie-tile"
    private var stopped = Set<ObjectIdentifier>()

    static func href(_ t: ReplayTile) -> String { "\(scheme)://t/\(t.z)/\(t.x)/\(t.y)" }

    static func tile(from url: URL) -> ReplayTile? {
        let parts = url.path.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return ReplayTile(z: parts[0], x: parts[1], y: parts[2])
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let tile = Self.tile(from: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        TileCache.shared.data(tile) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stopped.remove(id) != nil { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }
}

/// A WKWebView that shows one replay page.
struct ReplayWebView: UIViewRepresentable {
    let html: String
    /// Called with the page's own state (`window.__replay.state()` as JSON text) a moment after it loaded; ui-shot / check use
    var onState: ((String) -> Void)?

    static func make(handler: ReplaySchemeHandler?) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let handler { config.setURLSchemeHandler(handler, forURLScheme: ReplaySchemeHandler.scheme) }
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.bounces = false
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(onState: onState) }

    func makeUIView(context: Context) -> WKWebView {
        let view = Self.make(handler: context.coordinator.handler)
        view.navigationDelegate = context.coordinator
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: URL(string: "\(ReplaySchemeHandler.scheme)://t/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: URL(string: "\(ReplaySchemeHandler.scheme)://t/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = ReplaySchemeHandler()
        var loaded = ""
        let onState: ((String) -> Void)?

        init(onState: ((String) -> Void)?) { self.onState = onState }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let onState else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                webView.evaluateJavaScript("JSON.stringify(window.__replay ? window.__replay.state() : {missing:true})") { result, error in
                    onState((result as? String) ?? "error: \(error?.localizedDescription ?? "no result")")
                }
            }
        }
    }
}

/// Loads a page into a hidden web view and runs the page's own 50x self-test (check u39). Main thread.
@MainActor
final class ReplayProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let view = ReplayWebView.make(handler: nil)

    /// {"ready":true,"test":{...}} as JSON text, or an error text
    func run(html: String) async -> String {
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        view.navigationDelegate = self
        let loaded: Bool = await withCheckedContinuation { cont in
            continuation = cont
            view.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(false) }
        }
        guard loaded else { return "the page did not load" }
        let js = "JSON.stringify({ready: window.__replay && window.__replay.ready, errors: window.__replay ? window.__replay.errors : ['no __replay'], test: window.__replay ? window.__replay.test() : null})"
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            view.evaluateJavaScript(js) { result, error in
                cont.resume(returning: (result as? String) ?? "error: \(error?.localizedDescription ?? "no result")")
            }
        }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }
}
