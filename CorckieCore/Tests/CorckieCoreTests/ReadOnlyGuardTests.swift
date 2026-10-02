import XCTest
@testable import CorckieCore

/// TESTING §3 "Read-only" · ARCHITECTURE §1.4: the scooter link must never write.
/// Runs on Linux CI against the app's source text, so a write call fails the build before
/// any IPA is made (core-tests gate build-ipa).
final class ReadOnlyGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // CorckieCoreTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // CorckieCore
        .deletingLastPathComponent()    // repo root
        .appendingPathComponent("App")

    private func swiftFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func test_readOnly_scooterLinkExists() {
        let link = appFolder.appendingPathComponent("Adapters/ScooterLink.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path), "ScooterLink.swift moved? Update this guard.")
    }

    /// No write call anywhere in the app (CoreBluetooth's only way to send data to a peripheral).
    func test_readOnly_noWriteCallInTheApp() throws {
        let files = swiftFiles(in: appFolder)
        XCTAssertFalse(files.isEmpty)
        let banned = ["writeValue", "CBCharacteristicWriteType", ".withResponse", ".withoutResponse",
                      "canSendWriteWithoutResponse", "openL2CAPChannel"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) contains \(word): the scooter link is read-only")
            }
        }
    }

    /// The command and firmware-update UUIDs appear only in ScooterGatt's deny list, never in the app.
    func test_readOnly_deniedUUIDsNeverNamedInTheApp() throws {
        let fragments = ["FFF1", "FFC0", "FFC1", "FFC2", "2B12", "1912"]
        for file in swiftFiles(in: appFolder) {
            let text = try String(contentsOf: file, encoding: .utf8).uppercased()
            for fragment in fragments {
                XCTAssertFalse(text.contains(fragment), "\(file.lastPathComponent) names \(fragment)")
            }
        }
    }

    /// The test-only packet encoder lives in CorckieSim and must never reach ScooterLink.
    func test_readOnly_scooterLinkNeverImportsTheSimulator() throws {
        for file in swiftFiles(in: appFolder.appendingPathComponent("Adapters")) {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("import CorckieSim"), "\(file.lastPathComponent) imports CorckieSim")
        }
    }

    func test_readOnly_denyListCoversCommandsAndFirmwareUpdate() {
        XCTAssertTrue(ScooterGatt.isDenied("FFF1"))
        XCTAssertTrue(ScooterGatt.isDenied("0000fff1-0000-1000-8000-00805f9b34fb"))
        XCTAssertTrue(ScooterGatt.isDenied("f000ffc1-0451-4000-b000-000000000000"))
        XCTAssertTrue(ScooterGatt.isDenied("f000ffc2-0451-4000-b000-000000000000"))
        XCTAssertTrue(ScooterGatt.isDenied("00010203-0405-0607-0809-0a0b0c0d2b12"))
        XCTAssertFalse(ScooterGatt.isDenied("FFF2"))
        XCTAssertTrue(ScooterGatt.maySubscribe("0000FFF2-0000-1000-8000-00805F9B34FB"))
        XCTAssertFalse(ScooterGatt.maySubscribe("FFF1"))
        XCTAssertTrue(ScooterGatt.mayRead(characteristic: "2A26", inService: "180A"))
        XCTAssertFalse(ScooterGatt.mayRead(characteristic: "FFF2", inService: "FFF0"))
    }
}
