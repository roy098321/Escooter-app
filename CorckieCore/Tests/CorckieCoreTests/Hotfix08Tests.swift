import XCTest
@testable import CorckieCore

/// Hotfix 111.291126.08 (owner 24 Nov: the ride kept "recording" 30+ min after the scooter was switched off and he stopped).
/// Once the scooter is gone, walking or indoor GPS jumps no longer keep the ride open; riding on GPS after a lost link still does.
/// Synthetic numbers only.
final class Hotfix08Tests: XCTestCase {
    private func frame(_ t: Double, _ kmh: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = kmh > 0 ? 8 : 0
        f.batteryPct = 70
        f.voltage = 60
        return f
    }

    private func fix(_ t: Double, northM: Double, kmh: Double?) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: 5, speedMps: kmh.map { $0 / 3.6 } ?? -1)
    }

    /// 60 s of riding at 20 km/h (auto start), then the scooter disconnects WITHOUT the 0x80 flag at `offAt`.
    private func rideThenOff(offAt: Double = 60) -> (RideEngine, Double) {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        var north = 0.0
        var t = 0.0
        while t <= offAt {
            e.handle(.frame(frame(t, t < 1 ? 0 : 20)), at: t)
            if t >= 1 { north += 20 / 3.6 }
            e.handle(.fix(fix(t, northM: north, kmh: t < 1 ? 0 : 20)), at: t)
            t += 1
        }
        XCTAssertNotNil(e.ride, "the ride runs")
        e.handle(.disconnected, at: offAt + 0.5)
        return (e, north)
    }

    private func ended(_ events: [RideEngineEvent]) -> RideEnd? {
        for ev in events { if case .rideEnded(let end) = ev { return end } }
        return nil
    }

    func test_walkingAwayWithThePhone_endsTheRideAtTheSwitchOff() {
        var (e, north) = rideThenOff()
        var end: RideEnd?
        var t = 61.0
        while t <= 60 + 40 * 60, end == nil {          // 40 min of walking at 4.5 km/h
            north += 4.5 / 3.6
            end = ended(e.handle(.fix(fix(t, northM: north, kmh: 4.5)), at: t)) ?? ended(e.handle(.tick, at: t))
            t += 1
        }
        let e1 = try? XCTUnwrap(end, "walking no longer keeps the ride open")
        XCTAssertLessThanOrEqual(t, 60.5 + RideEngine.goneNoRidingS + 2, "ends ~3 min after the scooter went")
        XCTAssertEqual(e1?.endT ?? 0, 60.5, accuracy: 1.5, "the ride ends when the scooter went, not when the app noticed")
    }

    func test_indoorGpsJumps_withoutSpeed_endTheRide() {
        var (e, _) = rideThenOff()
        var end: RideEnd?
        var t = 61.0
        var i = 0
        while t <= 60 + 40 * 60, end == nil {           // fixes without a speed jumping 20 m back and forth
            i += 1
            end = ended(e.handle(.fix(fix(t, northM: 1000 + (i % 2 == 0 ? 20 : 0), kmh: nil)), at: t)) ?? ended(e.handle(.tick, at: t))
            t += 1
        }
        XCTAssertNotNil(end, "GPS jumps indoors no longer keep the ride open")
        XCTAssertLessThanOrEqual(t, 60.5 + RideEngine.goneNoRidingS + 2)
    }

    func test_lostLinkWhileStillRiding_keepsRecordingOnGps() {
        var (e, north) = rideThenOff()
        var t = 61.0
        while t <= 60 + 10 * 60 {                        // 10 min more at 20 km/h on GPS only
            north += 20 / 3.6
            XCTAssertNil(ended(e.handle(.fix(fix(t, northM: north, kmh: 20)), at: t)), "still riding at t \(t)")
            e.handle(.tick, at: t)
            t += 1
        }
        XCTAssertNotNil(e.ride, "a lost link while riding keeps going on the phone")
    }

    func test_scooterStillConnected_rulesUnchanged() {
        // connected and sending: only the 10-min standstill ends the ride (B63), the new rule never applies
        var e = RideEngine()
        e.handle(.connected, at: 0)
        var t = 0.0
        while t <= 60 { e.handle(.frame(frame(t, t < 1 ? 0 : 20)), at: t); t += 1 }
        while t <= 60 + 5 * 60 {
            XCTAssertNil(ended(e.handle(.frame(frame(t, 0)), at: t)), "standing at a light, connected (t \(t))")
            t += 1
        }
        XCTAssertNotNil(e.ride)
    }
}
