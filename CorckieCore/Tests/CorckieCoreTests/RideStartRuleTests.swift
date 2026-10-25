import XCTest
@testable import CorckieCore

/// B62: the ride starts at the first real riding movement (motor power or > 8 km/h for 3 s in a row, back-dated to its
/// beginning); pushing at walking pace, standing and a lifted wheel do not count; no riding movement = nothing saved.
/// Made-up frames and fixes, one a second.
final class RideStartRuleTests: XCTestCase {
    private func frame(_ t: Double, _ kmh: Double, amps: Double, odo: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = amps
        f.batteryPct = 80
        f.odometerKm = odo
        f.voltage = 50
        return f
    }

    private func fix(_ t: Double, northM: Double, kmh: Double) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: 5, speedMps: kmh / 3.6)
    }

    private struct Run {
        var e = RideEngine()
        var events: [RideEngineEvent] = []
        var t = 0.0
        var odo = 100.0
        var north = 0.0

        init() {
            e.handle(.connected, at: 0)
            events += e.handle(.frame(ScooterFrame(t: 0)), at: 0)
        }

        /// `kmh` on the wheel with `amps` of motor current; the phone moves too unless `lifted`
        mutating func go(for seconds: Double, kmh: Double, amps: Double, lifted: Bool = false) {
            let end = t + seconds
            while t < end {
                t += 1
                odo += lifted ? 0 : kmh / 3600
                if !lifted { north += kmh / 3.6 }
                var f = ScooterFrame(t: t)
                f.speedKmh = kmh
                f.currentA = amps
                f.batteryPct = 80
                f.odometerKm = odo
                f.voltage = 50
                events += e.handle(.frame(f), at: t)
                events += e.handle(.fix(PhoneFix(t: t, lat: 10 + north / 111_320, lon: -30, hAccM: 5, speedMps: lifted ? 0 : kmh / 3.6)), at: t)
            }
        }

        var ridingStarted: Double? {
            events.compactMap { if case let .ridingStarted(_, at) = $0 { return at } else { return nil } }.first
        }
        var ended: RideEnd? { events.compactMap { if case .rideEnded(let x) = $0 { return x } else { return nil } }.first }
        var cancelled: RideCancelReason? {
            events.compactMap { if case let .rideCancelled(_, _, r) = $0 { return r } else { return nil } }.first
        }
    }

    func test_B62_wheelingItOut_thenRiding_startsAtTheRidingMovement_backDated() {
        var run = Run()
        run.go(for: 60, kmh: 4, amps: 0)            // pushing it out of the lift and the building
        XCTAssertNil(run.ridingStarted, "walking pace without motor power is not riding")
        XCTAssertEqual(run.e.liveInput(at: run.t).rideElapsedS ?? 0, 0, accuracy: 0.01, "the clock has not started")
        run.go(for: 300, kmh: 20, amps: 8)
        XCTAssertEqual(run.ridingStarted ?? 0, 61, accuracy: 0.01, "back-dated to the beginning of the riding movement")
        XCTAssertEqual(run.e.liveInput(at: run.t).rideElapsedS ?? 0, run.t - 61, accuracy: 0.01)
        run.go(for: 700, kmh: 0, amps: 0)
        let end = run.ended
        XCTAssertNotNil(end)
        XCTAssertEqual(end?.ride.ridingStartT ?? 0, 61, accuracy: 0.01)
        XCTAssertEqual(end?.ride.firstMoveT ?? 0, 61, accuracy: 0.01, "Time runs from the first riding movement")
        XCTAssertEqual(end?.ride.trimStartT ?? 0, 61, accuracy: 0.01)
    }

    func test_B62_motorPowerAtLowSpeed_isRiding_after3s() {
        var run = Run()
        run.go(for: 2, kmh: 5, amps: 3)
        XCTAssertNil(run.ridingStarted, "2 s is not yet 3 s in a row")
        run.go(for: 5, kmh: 6, amps: 3)
        XCTAssertEqual(run.ridingStarted ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(run.e.phase, .riding)
    }

    func test_B62_onlyPushing_nothingIsSaved() {
        var run = Run()
        run.go(for: 90, kmh: 5, amps: 0)
        run.go(for: 700, kmh: 0, amps: 0)
        XCTAssertNil(run.ended, "no ride saved")
        XCTAssertNotNil(run.cancelled)
    }

    func test_B62_liftedWheelSpinning_isNotRiding() {
        var run = Run()
        run.go(for: 30, kmh: 25, amps: 6, lifted: true)
        XCTAssertNil(run.ridingStarted)
    }

    func test_B62_aBreakInTheMovement_startsTheCountAgain() {
        var run = Run()
        run.go(for: 2, kmh: 12, amps: 0)
        run.go(for: 2, kmh: 3, amps: 0)
        run.go(for: 4, kmh: 12, amps: 0)
        XCTAssertEqual(run.ridingStarted ?? 0, 5, accuracy: 0.01)
    }

    func test_B62_thresholdsAreNamed() {
        XCTAssertEqual(RideStartRule.ridingKmh, 8)
        XCTAssertEqual(RideStartRule.ridingHoldS, 3)
    }
}
