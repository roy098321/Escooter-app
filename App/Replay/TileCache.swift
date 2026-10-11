import CorckieCore
import Foundation

/// M5-04: map tiles for Ride Replay. OpenStreetMap raster tiles (the same look as the reference replay), fetched politely
/// (identifying User-Agent, at most 2 at a time, at most `ReplayBuilder.maxTiles` per replay) and kept on disk, so a replay
/// that was opened once plays with its map offline. A tile that cannot be had is simply left out.
final class TileCache {
    static let shared = TileCache()

    private let folder: URL
    private let session: URLSession
    private let gate = DispatchSemaphore(value: 2)
    private let queue = DispatchQueue(label: "corckie.tiles", qos: .utility, attributes: .concurrent)

    private init() {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "CorckieApp-RideReplay/1.0 (personal ride log; sideloaded)"]
        session = URLSession(configuration: config)
    }

    private func file(_ t: ReplayTile) -> URL {
        folder.appendingPathComponent("\(t.z)_\(t.x)_\(t.y).png")
    }

    func cached(_ t: ReplayTile) -> Data? {
        try? Data(contentsOf: file(t))
    }

    /// Cache first, then the network. Calls back on a background queue.
    func data(_ t: ReplayTile, completion: @escaping (Data?) -> Void) {
        if let hit = cached(t) { completion(hit); return }
        guard t.z >= 0, t.z <= 19, let url = URL(string: "https://tile.openstreetmap.org/\(t.z)/\(t.x)/\(t.y).png") else { completion(nil); return }
        queue.async {
            self.gate.wait()
            let task = self.session.dataTask(with: url) { data, response, _ in
                self.gate.signal()
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                if ok, let data, !data.isEmpty {
                    try? data.write(to: self.file(t), options: .atomic)
                    completion(data)
                } else {
                    completion(nil)
                }
            }
            task.resume()
        }
    }

    /// Every tile that can be had (cached or fetched); the others are missing from the result.
    func fetchAll(_ tiles: [ReplayTile], progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> [ReplayTile: Data] {
        await withCheckedContinuation { (cont: CheckedContinuation<[ReplayTile: Data], Never>) in
            let list = Array(tiles.prefix(ReplayBuilder.maxTiles))
            guard !list.isEmpty else { cont.resume(returning: [:]); return }
            let lock = NSLock()
            var result: [ReplayTile: Data] = [:]
            var done = 0
            for tile in list {
                data(tile) { bytes in
                    lock.lock()
                    if let bytes { result[tile] = bytes }
                    done += 1
                    let finished = done == list.count
                    let count = done
                    let snapshot = result
                    lock.unlock()
                    progress(count, list.count)
                    if finished { cont.resume(returning: snapshot) }
                }
            }
        }
    }

    /// Size on disk, for Developer
    func sizeText() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var bytes = 0
        for n in names {
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(n).path)
            bytes += (attrs?[.size] as? Int) ?? 0
        }
        return "\(names.count) tiles, " + String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
