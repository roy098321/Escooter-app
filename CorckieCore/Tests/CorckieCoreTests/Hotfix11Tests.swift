@testable import CorckieCore
import XCTest

/// Hotfix 111.291126.11 (24 Nov): the crash at every ride close (B111), crash details kept (B112), the music given back after every
/// app sound (B107–B110) and the G500 % after a hard ride (B113). Synthetic numbers only; app code is checked as text (Linux).
final class Hotfix11Tests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: B111 the close crash

    func test_B111_wetIsText() {
        XCTAssertFalse(EnergyHint.isWet(override: nil, weather: "dry"))
        XCTAssertTrue(EnergyHint.isWet(override: nil, weather: "rain"))
        XCTAssertTrue(EnergyHint.isWet(override: "wet", weather: "dry"), "the rider's own answer wins")
        XCTAssertFalse(EnergyHint.isWet(override: "dry", weather: "rain"))
        XCTAssertFalse(EnergyHint.isWet(override: nil, weather: nil), "no weather yet = dry")
    }

    func test_B111_wetNeverReadAsANumber() throws {
        let s = try source("App/Notifier/EnergyHintService.swift")
        XCTAssertFalse(s.contains("let wet: Int?"), "ride.wet is TEXT: an Int read traps in GRDB (4 crashes on 24 Nov)")
        XCTAssertTrue(s.contains("EnergyHint.isWet(override: extra?[\"wetOverride\"] as String?, weather: extra?[\"wet\"] as String?)"))
    }

    // MARK: B112 crash details

    func test_B112_crashDetailsKeptAndExported() throws {
        let c = try source("App/Diagnostics/CrashCatcher.swift")
        XCTAssertTrue(c.contains("c.jsonRepresentation().write(to: url)"))
        XCTAssertTrue(c.contains("static let keptCrashFiles = 10"))
        XCTAssertTrue(try source("App/Diagnostics/Exporter.swift").contains("for file in CrashCatcher.crashFiles()"))
    }

    // MARK: B107–B110 the music comes back

    func test_B107_toB110_soundPlayerGivesTheMusicBack() throws {
        let s = try source("App/Audio/SoundPlayer.swift")
        XCTAssertTrue(s.contains("if start(kind, endsWarning: true) { return true }"), "B107: a warning tone on its own ends its duck")
        XCTAssertTrue(s.contains("AVAudioSession.interruptionNotification"), "B108: a call or Siri can't leave a warning open")
        XCTAssertTrue(s.contains("private func armSafetyNet()"), "B108: nothing playing = nothing in flight")
        XCTAssertTrue(s.contains("func audioPlayerDecodeErrorDidOccur"), "B108: a sound that never finishes still ends")
        XCTAssertTrue(s.contains("pendingRelease = true"), "B109: tried again when the last sound ends")
        XCTAssertTrue(s.contains("RideAudio.restoreRide()"), "B110: back to the ride's own setting after a nice sound")
        XCTAssertFalse(s.contains("try? s.setActive(false, options: .notifyOthersOnDeactivation)\n        try? s.setCategory"),
                       "B109: a refused deactivation is noticed, not swallowed")
    }

    // MARK: B113 G500 % after a hard ride

    private func packet(volts: Double, amps: Double = 0.03, raw: Int = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x24; b[1] = 0x20; b[2] = 0x12; b[3] = 0x34
        func put(_ i: Int, _ v: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF) }
        put(4, Int((volts * 100).rounded())); put(6, Int((amps * 100).rounded())); b[8] = 0x2C
        put(10, raw); put(14, 2500); b[16] = 1
        return b
    }

    func test_B113_tiredVoltageAfterARide_isNotRead() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 64.0), at: 0)                        // switched on rested: about 80 %
        let start = try XCTUnwrap(a.g500RestPct)
        var t = 0.0
        for _ in 0..<(20 * 60) {                                         // 20 min at 25 A = 8.3 Ah = ~40 % of 21 Ah
            t += 1
            _ = a.ingest(packet(volts: 57, amps: 25, raw: 900), at: t)
        }
        let counted = try XCTUnwrap(a.g500RestPct)
        XCTAssertEqual(Double(start - counted), 25.0 * 20 / 60 / 21 * 100, accuracy: 1.5)
        // arrived: the voltage is still low (24 Nov: 56.7 V = 8 %) for minutes; 1 min standing keeps the counted level
        for i in 1...60 { _ = a.ingest(packet(volts: 56.7), at: t + Double(i)) }
        XCTAssertEqual(a.g500RestPct, counted, "a tired pack's voltage is not read as the level")
        // after 5 min the pack has recovered: the resting voltage counts again
        _ = a.ingest(packet(volts: 61.0), at: t + FrameAssembler.g500RecoverS + 1)
        XCTAssertEqual(a.g500RestPct, LiIonCurve.pct(packV: 61.0, cells: 16))
    }

    func test_B113_aQuickOffAndOn_isStillATiredPack() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 64.0), at: 0)
        for i in 1...600 { _ = a.ingest(packet(volts: 57, amps: 25, raw: 900), at: Double(i)) }
        a.reset()                                                        // switched off and on within a minute
        XCTAssertEqual(a.g500LastLoadT, 600, "the last load is remembered across a disconnect")
        _ = a.ingest(packet(volts: 56.8), at: 640)
        let first = try XCTUnwrap(a.g500RestPct, "the first reading of a connection is still shown (nothing else to go on)")
        for i in 1...30 { _ = a.ingest(packet(volts: 57.5), at: 640 + Double(i)) }
        XCTAssertEqual(a.g500RestPct, first, "no re-reading until the pack has recovered")
        _ = a.ingest(packet(volts: 61.0), at: 600 + FrameAssembler.g500RecoverS + 1)
        XCTAssertEqual(a.g500RestPct, LiIonCurve.pct(packV: 61.0, cells: 16), "the recovered reading replaces it")
    }
}
