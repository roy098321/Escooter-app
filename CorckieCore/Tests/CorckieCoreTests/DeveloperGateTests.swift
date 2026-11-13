import XCTest
@testable import CorckieCore

/// The repo is public: no test or source may hold the plain password, only its hash.
final class DeveloperGateTests: XCTestCase {
    func test_sha256KnownVector() {
        XCTAssertEqual(DeveloperGate.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(DeveloperGate.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func test_wrongPasswordsStayClosed() {
        for attempt in ["", "wrong", "abc", "000000", "123456"] { XCTAssertFalse(DeveloperGate.accepts(attempt), attempt) }
    }

    func test_gateIsExactlyTheHashComparison() {
        XCTAssertEqual(DeveloperGate.passwordHash.count, 64)
        for attempt in ["a", "b c", "Zz9"] {
            XCTAssertEqual(DeveloperGate.accepts(attempt), DeveloperGate.sha256Hex(attempt) == DeveloperGate.passwordHash)
        }
    }

    func test_noPlainPasswordLeftInTheAppSources() throws {
        // search this repo's Swift sources for the plain text, built from pieces so this file does not contain it itself
        let plain = ["123", "abc"].joined()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        var hits: [String] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(plain) { hits.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(hits, [])
    }
}
