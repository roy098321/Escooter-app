import CorckieCore
import Foundation

/// u14 (M1-12): the live ride screen's display rules on made-up inputs: Ready (no clock, no stop button, can be
/// closed), no way out of a ride but the held stop button, SLOW 45 / 43, GPS speed greyed and labelled, "~N% est.",
/// banners one at a time and locked from 5 km/h, "No GPS" after 10 s, hold to end needs a full second.
enum LiveScreenCheck {
    static func run() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }

        var d = LiveScreenDriver()
        let ready = d.update(LiveInput(scooterSpeedKmh: 0, scooterBatteryPct: 91, phase: .ready), at: 0)
        expect(ready.mode == .ready && ready.canClose && !ready.showClock && !ready.showHoldToEnd && ready.banner == nil,
               "Ready: no clock, no stop button, can be closed")

        var r = LiveScreenDriver()
        let riding = r.update(LiveInput(scooterSpeedKmh: 30, scooterBatteryPct: 80, phase: .riding, rideElapsedS: 61), at: 0)
        expect(!riding.canClose && riding.showHoldToEnd && riding.clockText == "1:01", "riding: no close button, hold to end, clock")

        var s = LiveScreenDriver()
        let slow = [44.9, 45.1, 44.0, 42.9].enumerated().map { s.update(LiveInput(scooterSpeedKmh: $0.element), at: Double($0.offset)).tiles.slow }
        expect(slow == [false, true, true, false], "SLOW on above 45, off below 43")

        var g = LiveScreenDriver()
        let gps = g.update(LiveInput(gpsSpeedKmh: 31, scooterLinked: false, scooterBatteryPct: 64, estimatedBatteryPct: 61,
                                     phoneMode: true), at: 0)
        expect(gps.tiles.speedLabel == "GPS" && gps.tiles.speedGreyed && gps.tiles.batteryText == "~61% est.",
               "phone mode: GPS label greyed, ~61% est.")
        expect(gps.banner?.banner == .disconnected && gps.dashedPath, "phone mode: disconnected banner, dashed path")

        var b = LiveScreenDriver()
        _ = b.update(LiveInput(scooterSpeedKmh: 0), at: 0)
        let fast = b.update(LiveInput(scooterSpeedKmh: 30, scooterTempC: 91), at: 1)
        expect(fast.banner?.banner == .hot && fast.banner?.tappable == false && !b.tapBanner(speedKmh: 30),
               "hot banner: not tappable at 30 km/h")
        expect(b.update(LiveInput(scooterSpeedKmh: 0, scooterTempC: 91), at: 2).banner?.tappable == true, "tappable when stopped")

        var n = LiveScreenDriver()
        expect(n.update(LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 9), at: 0).chips.isEmpty, "no GPS chip at 9 s")
        expect(n.update(LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 10), at: 1).dotGreyed, "dot greyed at 10 s")

        var h = HoldToEnd()
        h.begin(at: 0)
        expect(!h.completed(at: 0.9) && h.completed(at: 1.0), "hold to end: 1 s, not less")
        expect(!LiveScreenLogic.coverShown(phase: .ready, readyRequested: false)
               && LiveScreenLogic.coverShown(phase: .riding, readyRequested: false), "the full-screen cover follows the ride")

        CheckResults.shared.set("u14", ok ? .pass : .fail, notes.joined(separator: " \u{00B7} "))
    }
}
