import XCTest
@testable import CorckieCore

/// F-38: a ride ends at its last movement; stops inside the ride count in its Time. Made-up samples and engine inputs.
final class RideEndTimeTests: XCTestCase {
    private func frame(_ t: Double, _ kmh: Double, odo: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = kmh > 0 ? 8 : 0
        f.batteryPct = 80
        f.odometerKm = odo
        f.voltage = 50
        return f
    }

    func test_F38_storedSamples_endAtTheLastMovement() {
        var s: [RideSample] = []
        for i in 0..<60 { s.append(RideSample(t: Double(i) * 5, speedKmh: i < 40 ? 20 : 0)) }
        XCTAssertEqual(RideEndTime.endS(s), 195, "the standing tail after 195 s is not ride time")
        XCTAssertNil(RideEndTime.endS([RideSample(t: 0, speedKmh: 0)]))
    }

    func test_F38_standstillEnd_endsAtTheLastMovement_andAStopInsideCountsInTime() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0, 0, odo: 100)), at: 0)
        e.handle(.startPressed, at: 1)
        var events: [RideEngineEvent] = []
        var odo = 100.0
        var t = 1.0
        func ride(until end: Double, kmh: Double) {
            while t < end {
                if kmh > 0 { odo += kmh / 3600 }
                events += e.handle(.frame(frame(t, kmh, odo: odo)), at: t)
                t += 1
            }
        }
        ride(until: 300, kmh: 20)
        ride(until: 420, kmh: 0)          // a 2 min stop with the scooter on
        ride(until: 700, kmh: 20)
        ride(until: 1_400, kmh: 0)        // standing until the 10 min standstill ends it
        let end = events.compactMap { if case .rideEnded(let x) = $0 { return x } else { return nil } }.first
        XCTAssertEqual(end?.reason, .standstill)
        XCTAssertEqual(end?.endT ?? 0, 699, accuracy: 1.5, "ends at the last movement")
        XCTAssertEqual(end?.ride.stops.count, 1, "the stop inside the ride is kept")
        XCTAssertEqual(RideEndTime.timeS(firstMoveS: end?.ride.firstMoveT, lastMoveS: end?.endT) ?? 0, 698, accuracy: 2,
                       "Time includes the stop")
    }
}
