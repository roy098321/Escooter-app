import XCTest
@testable import CorckieCore

/// M6-03 (C30): when the sunlight style is on, and the two speed palettes (also in the replay page).
final class DisplayStyleTests: XCTestCase {
    func testOnAndOffAreManual() {
        XCTAssertTrue(SunlightRule.active(setting: "On", brightness: 0.2, hour: 23))
        XCTAssertFalse(SunlightRule.active(setting: "Off", brightness: 1, hour: 12, increaseContrast: true, reduceTransparency: true))
    }

    func testAutoFollowsBrightnessInDaylight() {
        XCTAssertTrue(SunlightRule.active(setting: "Auto", brightness: 0.9, hour: 12))
        XCTAssertTrue(SunlightRule.active(setting: "Auto", brightness: 1.0, hour: 6))
        XCTAssertFalse(SunlightRule.active(setting: "Auto", brightness: 0.89, hour: 12))
        XCTAssertFalse(SunlightRule.active(setting: "Auto", brightness: 1.0, hour: 22), "a bright screen at night is a choice")
        XCTAssertFalse(SunlightRule.active(setting: "Auto", brightness: 1.0, hour: 5))
        XCTAssertFalse(SunlightRule.active(setting: "Auto", brightness: nil, hour: 12))
        XCTAssertFalse(SunlightRule.active(setting: "", brightness: 0.3, hour: 12), "unknown setting counts as Auto")
    }

    func testIosAccessibilitySwitchesAskForTheSameInAuto() {
        XCTAssertTrue(SunlightRule.active(setting: "Auto", brightness: 0.3, hour: 23, increaseContrast: true))
        XCTAssertTrue(SunlightRule.active(setting: "Auto", brightness: nil, hour: 3, reduceTransparency: true))
    }

    func testPalettesHaveFiveColoursAndTheColourBlindOneIsDifferent() {
        XCTAssertEqual(SpeedPalette.standardHex.count, LivePath.bucketCount)
        XCTAssertEqual(SpeedPalette.colourBlindHex.count, LivePath.bucketCount)
        XCTAssertEqual(Set(SpeedPalette.colourBlindHex).count, 5)
        XCTAssertTrue(Set(SpeedPalette.colourBlindHex).isDisjoint(with: SpeedPalette.standardHex))
        XCTAssertEqual(SpeedPalette.hex(colourBlind: true), SpeedPalette.colourBlindHex)
        for h in SpeedPalette.standardHex + SpeedPalette.colourBlindHex { XCTAssertNotNil(SpeedPalette.rgb(h), h) }
        XCTAssertNil(SpeedPalette.rgb("red"))
        XCTAssertEqual(SpeedPalette.rgb("#0072B2")?.b ?? 0, 178.0 / 255, accuracy: 0.001)
    }

    func testColourBlindPaletteHasNoRedGreenPair() {
        // a red-green pair would be two colours that differ mostly in the red-green axis at the same brightness; the colour-blind
        // palette is blue -> orange-red: its green channel never beats red AND blue together except the yellow, and blue is always
        // the smallest or the largest end
        let rgb = SpeedPalette.colourBlindHex.compactMap(SpeedPalette.rgb)
        XCTAssertFalse(rgb.contains { $0.g > $0.r + 0.15 && $0.g > $0.b + 0.15 }, "no green-dominant colour")
    }

    func testLegendNamesTheColours() {
        XCTAssertTrue(SpeedPalette.legendText(colourBlind: false).contains("light green slow, red fast"))
        XCTAssertTrue(SpeedPalette.legendText(colourBlind: true).contains("blue slow"))
    }

    func testReplayPageTakesThePaletteAndTheContrast() throws {
        var rows: [ReplayRow] = []
        for t in stride(from: 0, through: 100, by: 5) {
            let s = Double(t)
            rows.append(ReplayRow(t: s, lat: 10 + s * 0.00004, lon: -30 + s * 0.00004, hAccM: 5, speedKmh: 20, gpsKmh: 19, altM: 30,
                                  powerW: 200, batteryPct: 80, tempC: 30))
        }
        let d = try XCTUnwrap(ReplayBuilder.make(title: "Ride", dateLabel: "6 Oct", startAtMs: 1_790_000_000_000, utcOffsetMin: 180, rows: rows,
                                                 stops: [], info: ReplayRideInfo(distanceM: 1_000, startPct: 80, endPct: 79)))
        let plain = ReplayHTML.build(d) { _ in nil }
        XCTAssertTrue(plain.contains("var HEX = ['#7fd37f'"))
        XCTAssertFalse(plain.contains("--bg:#ffffff;--card:#ffffff;--ink:#000000"))
        let blind = ReplayHTML.build(d, colourBlind: true) { _ in nil }
        XCTAssertTrue(blind.contains("var HEX = ['#0072b2', '#56b4e9', '#f0e442', '#e69f00', '#d55e00'];"))
        XCTAssertFalse(blind.contains("#7fd37f"))
        let sun = ReplayHTML.build(d, highContrast: true) { _ in nil }
        XCTAssertTrue(sun.contains("--ink:#000000"))
        XCTAssertEqual(sun.components(separatedBy: "</style>").count - 1, 1)
    }
}
