import CorckieCore
import Foundation
import XCTest

/// Batch 11 guard tests (N11-1 tyre hint, N11-2 Garage, N11-3 B100 logo ring, N11-4 thank-you, N11-5 B101 G500).
/// Logic in CorckieCore, plus checks on the app's source text and assets (Linux CI cannot build the app).
final class Batch111Tests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: N11-3 · B100 white ring around the Home logo

    /// RGBA pixels of a PNG written by Tools/b100_headermark.py (zlib stored blocks, so no inflate is needed on Linux).
    private func storedPNG(_ url: URL) throws -> (w: Int, h: Int, px: [UInt8]) {
        let d = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }
        var i = 8, w = 0, h = 0
        var z: [UInt8] = []
        while i + 8 <= d.count {
            let len = u32(i), type = String(bytes: d[i + 4..<i + 8], encoding: .ascii) ?? ""
            if type == "IHDR" {
                w = u32(i + 8); h = u32(i + 12)
                XCTAssertEqual(d[i + 16], 8, "8 bits"); XCTAssertEqual(d[i + 17], 6, "RGBA")
            }
            if type == "IDAT" { z += d[i + 8..<i + 8 + len] }
            i += 12 + len
        }
        var raw: [UInt8] = [], j = 2   // skip the zlib header
        while j < z.count - 4 {
            let header = z[j], last = header & 1
            guard (header >> 1) & 3 == 0 else { throw NSError(domain: "B100", code: 1, userInfo: [NSLocalizedDescriptionKey: "not stored; re-run Tools/b100_headermark.py"]) }
            let n = Int(z[j + 1]) | Int(z[j + 2]) << 8
            raw += z[j + 5..<j + 5 + n]
            j += 5 + n
            if last == 1 { break }
        }
        var px: [UInt8] = []
        for y in 0..<h {
            let row = raw[(y * (w * 4 + 1))..<((y + 1) * (w * 4 + 1))]
            XCTAssertEqual(row.first, 0, "filter 0")
            px += row.dropFirst()
        }
        return (w, h, px)
    }

    /// No light (white / light grey) pixel in the outer ring of the asset; the disc ends inside the 34 pt clip.
    func test_B100_noLightRimAroundTheHomeLogo() throws {
        for scale in ["2x", "3x"] {
            let url = appFolder.appendingPathComponent("Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@\(scale).png")
            let (w, h, px) = try storedPNG(url)
            XCTAssertEqual(w, h)
            let c = Double(w) / 2
            var light = 0, maxR = 0.0
            for y in 0..<h {
                for x in 0..<w {
                    let k = (y * w + x) * 4
                    let a = px[k + 3]
                    let r = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot() / c
                    if a > 0 { maxR = max(maxR, r) }
                    if r >= 0.85, a > 40, min(px[k], px[k + 1], px[k + 2]) > 150 { light += 1 }
                }
            }
            XCTAssertEqual(light, 0, "\(scale): light pixels in the outer ring")
            XCTAssertLessThan(maxR, 0.97, "\(scale): mask pulled in ~4 %")
            XCTAssertGreaterThan(maxR, 0.9, "\(scale): the disc is not shrunk more than needed")
        }
    }

    // MARK: N11-5 · B101 G500

    func test_B101_g500FoundAndNamed_unknownIgnored() {
        XCTAssertTrue(ScooterGatt.isScooter(name: "G500", manufacturerData: []))
        XCTAssertTrue(ScooterGatt.isScooter(name: "G2", manufacturerData: []))
        XCTAssertEqual(KnownScooters.modelName(advertisedName: "G500", makerTagged: false), "RND G500")
        XCTAssertFalse(ScooterGatt.isScooter(name: "Unknown", manufacturerData: []))
        XCTAssertEqual(KnownScooters.modelName(advertisedName: "Unknown", makerTagged: false), "Scooter")
    }
}
