import Foundation

/// Finds files in `Tests/Fixtures/` next to the test sources (no bundle resources needed on Linux).
enum Fixtures {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // CorckieCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func all(withExtension ext: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix("." + ext) }.sorted().map(url)
    }
}
