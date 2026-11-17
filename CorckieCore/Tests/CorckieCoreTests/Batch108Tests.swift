import CorckieCore
import XCTest

/// Batch 8 guard tests (in-ride signals).
final class Batch108Tests: XCTestCase {
    func test_N8_2_batteryTileLevels() {
        XCTAssertEqual(BatteryTileLevel.level(pct: 21), .normal)
        XCTAssertEqual(BatteryTileLevel.level(pct: 20), .low)
        XCTAssertEqual(BatteryTileLevel.level(pct: 11), .low)
        XCTAssertEqual(BatteryTileLevel.level(pct: 10), .critical)
        XCTAssertEqual(BatteryTileLevel.level(pct: nil), .normal)
        XCTAssertEqual(BatteryTileLevel.number("18%", level: .low, colourBlind: true), "\u{25BC} 18%")
        XCTAssertEqual(BatteryTileLevel.number("18%", level: .low, colourBlind: false), "18%")
    }

    func test_N8_1_rankingMaxThreeRedFirst_overflowToSummary() {
        var strip = WarningStrip()
        strip.update(on: [.offlineMap, .noGps, .motorVeryHot, .disconnected, .rainSoon], wheelSpeedKmh: 20, at: 0)
        XCTAssertEqual(strip.shown, [.motorVeryHot, .disconnected, .noGps])
        XCTAssertEqual(strip.shown.first?.colour, .red)
        XCTAssertEqual(strip.neverShown, [.rainSoon, .offlineMap])
        strip.update(on: [.offlineMap], wheelSpeedKmh: 20, at: 1)
        XCTAssertEqual(strip.shown, [.offlineMap], "a waiting light takes a free slot")
        XCTAssertEqual(strip.neverShown, [.rainSoon])
        strip.update(on: [], wheelSpeedKmh: 20, at: 2)
        XCTAssertTrue(strip.shown.isEmpty, "nothing when all is fine")
    }

    func test_N8_1_expandOnlyAtWheelSpeedZeroForOneSecond() {
        var strip = WarningStrip()
        strip.update(on: [.noGps], wheelSpeedKmh: 0, at: 10)
        XCTAssertFalse(strip.canExpand(at: 10.5))
        XCTAssertTrue(strip.canExpand(at: 11))
        strip.update(on: [.noGps], wheelSpeedKmh: 3, at: 11.2)
        XCTAssertFalse(strip.canExpand(at: 12), "moving: a tap does nothing")
        strip.update(on: [.disconnected], wheelSpeedKmh: nil, at: 13)
        XCTAssertFalse(strip.canExpand(at: 20), "no wheel speed (disconnected): no expand, GPS speed never counts")
    }

    func test_N8_3_levelTwoToneOncePerRide() {
        var strip = WarningStrip()
        XCTAssertEqual(strip.update(on: [.noGps, .offlineMap], wheelSpeedKmh: 10, at: 0), [.noGps])
        XCTAssertEqual(strip.update(on: [.noGps], wheelSpeedKmh: 10, at: 1), [])
        XCTAssertEqual(WarningLight.motorVeryHot.level, 3)
        XCTAssertEqual(WarningLight.offlineMap.level, 1)
        strip.rideEnded()
        XCTAssertEqual(strip.update(on: [.noGps], wheelSpeedKmh: 10, at: 0), [.noGps], "a new ride may tone again")
    }

    /// N8-1: the strip replaces the very hot / hot / disconnected / No GPS / phone battery banners and the No GPS / Offline map
    /// chips on the live screen; other banners stay
    func test_N8_1_stripReplacesThoseBannersAndChips() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let live = try String(contentsOf: app.appendingPathComponent("UI/Live/LiveRideView.swift"), encoding: .utf8)
        XCTAssertTrue(live.contains("WarningStripView(lights: s.warnings"))
        XCTAssertTrue(live.contains("LiveScreenState.stripBanners.contains($0.banner)"))
        XCTAssertFalse(live.contains("ForEach(Array(s.chips.enumerated())"), "the No GPS / Offline map chips are lights now")
        XCTAssertEqual(LiveScreenState.stripBanners, [.veryHot, .hot, .disconnected, .noGps, .phoneBatteryLow])
        let strip = try String(contentsOf: app.appendingPathComponent("UI/Live/WarningStripView.swift"), encoding: .utf8)
        XCTAssertTrue(strip.contains("guard expandable else { return }"), "while moving a tap does nothing")
    }

    func test_N8_4_turnBackInTwoSteps() {
        XCTAssertEqual(V09Message.turnBackSoon.line, "Turn-back point in one kilometre.")
        XCTAssertEqual(V09Message.turnBackNow.line, "Turn back now to make it back.")
        XCTAssertTrue(V09Message.turnBackSoon.urgent && V09Message.turnBackNow.urgent)
        XCTAssertTrue(V09Message.samples.contains(.turnBackSoon) && V09Message.samples.contains(.turnBackNow))
        XCTAssertFalse(V09Message.samples.contains(.pointOfNoReturn(metres: 300)), "the single 300 m line is replaced")
        XCTAssertEqual(V09Director.turnBackSoonM, 1000)
    }

    /// N8-1 "Dark before you arrive": offline sun position (made-up place on the equator, 0° lon)
    func test_N8_1_darkBeforeArrival() {
        // 2026-03-20 (equinox) at the equator, 0°: noon ~12:07 UTC, sunset ~18:07, civil dusk ~18:30
        let day = 1_773_964_800.0          // 2026-03-20 00:00 UTC
        XCTAssertGreaterThan(SunPosition.elevationDeg(lat: 0, lon: 0, epochS: day + 12 * 3600), 80)
        XCTAssertTrue(SunPosition.isDark(lat: 0, lon: 0, epochS: day + 1 * 3600))
        XCTAssertFalse(SunPosition.isDark(lat: 0, lon: 0, epochS: day + 17 * 3600))
        XCTAssertTrue(SunPosition.darkBeforeArrival(lat: 0, lon: 0, nowS: day + 18 * 3600, remainingS: 45 * 60))
        XCTAssertFalse(SunPosition.darkBeforeArrival(lat: 0, lon: 0, nowS: day + 15 * 3600, remainingS: nil))
        XCTAssertFalse(SunPosition.darkBeforeArrival(lat: 0, lon: 0, nowS: day + 22 * 3600, remainingS: nil), "already dark: cleared")
    }
}
