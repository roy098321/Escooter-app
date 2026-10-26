import XCTest
@testable import CorckieCore

/// Hotfix 01 (H6): the speed sweet spot always said "0 steady stretches" because it wanted readings at most 3 s apart while rides
/// store one every 5 s. The gap now follows the recorder's interval.
final class Hotfix01SweetSpotTests: XCTestCase {
    private func ride(every dt: Double, seconds: Double, kmh: Double) -> [SpeedSample] {
        stride(from: 0.0, through: seconds, by: dt).map { SpeedSample(tS: $0, speedKmh: kmh, powerW: 300) }
    }

    func test_fiveSecondSamples_threeSteadyMinutes_giveAStretch() {
        var cuts = SweetSpotInsight.Cuts()
        let out = SweetSpotInsight.stretches(rideId: "h6", samples: ride(every: 5, seconds: 180, kmh: 25), cuts: &cuts)
        XCTAssertGreaterThanOrEqual(out.count, 1, "3 min at a steady 25 km/h at 5 s samples is at least one stretch")
        XCTAssertEqual(out.first?.speedKmh ?? 0, 25, accuracy: 0.01)
    }

    func test_theRecorderIntervalAlwaysFitsTheGap() {
        let dt = RideRecorderCore.sampleIntervalS
        XCTAssertGreaterThan(SweetSpotInsight.maxGapS, dt, "two neighbouring recorder readings never break a stretch")
        XCTAssertEqual(SweetSpotInsight.maxGapS, 2.5 * dt, accuracy: 1e-9)
        var cuts = SweetSpotInsight.Cuts()
        let out = SweetSpotInsight.stretches(rideId: "rec", samples: ride(every: dt, seconds: 180, kmh: 22), cuts: &cuts)
        XCTAssertFalse(out.isEmpty, "a steady ride at the recorder's own interval gives stretches")
    }

    func test_aRealGapStillBreaks() {
        var cuts = SweetSpotInsight.Cuts()
        let a = ride(every: 5, seconds: 50, kmh: 25)
        let b = ride(every: 5, seconds: 50, kmh: 25).map { SpeedSample(tS: $0.tS + 80, speedKmh: $0.speedKmh, powerW: $0.powerW) }
        XCTAssertTrue(SweetSpotInsight.stretches(rideId: "g", samples: a + b, cuts: &cuts).isEmpty, "a 30 s hole splits two 50 s pieces")
    }
}
