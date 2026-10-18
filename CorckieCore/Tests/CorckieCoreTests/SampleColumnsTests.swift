import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// B25 (T-04): every `ride_sample` column gets a value: gear, cap, brake and light from packet A, course and GPS altitude from the
/// phone's fix, and at ride close moving, stop and cumulative distance from the same rules as the ride metrics.
final class SampleColumnsTests: XCTestCase {
    private func rideTwoWithPhone() throws -> SimStream {
        let text = try Fixtures.text("F3_ride2_merged.csv")
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let start = try XCTUnwrap(LogReader.mergedStartTimeOfDayS(text))
        let phone = try PhoneSource.events(locationText: Fixtures.text("F4_ride2_location.csv"),
                                           barometerText: Fixtures.text("F4_ride2_barometer.csv"),
                                           scooterStartTimeOfDayS: start)
        return SimStream(scooter: try sim.events(from: text), phone: phone)
    }

    func test_B25_ride2WithPhone_samplerFillsTheFrameAndFixColumns() throws {
        let r = EngineRunner.run(try rideTwoWithPhone())
        let end = try XCTUnwrap(r.ends.first)
        let samples = try XCTUnwrap(r.samples[end.ride.seq])
        XCTAssertGreaterThan(samples.count, 100)
        let scooter = samples.filter { $0.speedKmh != nil }
        XCTAssertTrue(scooter.allSatisfy { $0.gear != nil && $0.capKmh != nil && $0.brake != nil && $0.light != nil },
                      "every scooter sample has gear, cap, brake and light")
        XCTAssertTrue(samples.contains { $0.courseDeg != nil }, "course from the phone's fix")
        XCTAssertTrue(samples.contains { $0.altFixedM != nil }, "GPS altitude from the phone's fix")
        XCTAssertTrue(samples.allSatisfy { ($0.courseDeg ?? 0) >= 0 && ($0.courseDeg ?? 0) < 360 }, "an unknown course (-1) stays empty")
    }

    func test_B25_rideClose_annotations_matchTheTotals() throws {
        let r = EngineRunner.run(try rideTwoWithPhone())
        let end = try XCTUnwrap(r.ends.first)
        let samples = try XCTUnwrap(r.samples[end.ride.seq])
        let notes = end.sampleAnnotations(samples)
        XCTAssertEqual(notes.count, samples.count)
        XCTAssertTrue(notes.contains { $0.moving })
        XCTAssertTrue(notes.contains { !$0.moving })
        if !end.ride.stops.isEmpty {
            XCTAssertTrue(notes.contains { $0.stopIndex != nil }, "samples in a stop name it")
            XCTAssertTrue(notes.filter { $0.stopIndex != nil }.allSatisfy { !$0.moving }, "a sample in a stop is not moving")
        }
        for i in 1..<notes.count { XCTAssertGreaterThanOrEqual(notes[i].distanceM, notes[i - 1].distanceM, "distance never goes back") }
        let m = end.metrics(samples)
        XCTAssertEqual(try XCTUnwrap(notes.last).distanceM, m.distanceM, accuracy: 200, "the last sample's distance ≈ the ride's")
        // the moving time from the flags is the ride's moving time
        let movingCount = notes.filter(\.moving).count
        XCTAssertEqual(Double(movingCount) * 5, m.movingS, accuracy: 30)
    }

    func test_B25_annotator_stopsAndGpsOnlyDistance() {
        // 0–60 s at 18 km/h with the odometer, a stop 20–30 s
        var samples: [RideSample] = []
        for i in 0...12 {
            let t = Double(i) * 5
            let v = (20...30).contains(t) ? 0.0 : 18
            samples.append(RideSample(t: t, speedKmh: v, odometerKm: 100 + Double(i) * 0.025))
        }
        let notes = SampleAnnotator.annotate(samples, stops: [RideStopSpan(startT: 20, endT: 30)])
        XCTAssertEqual(notes.filter { $0.stopIndex == 0 }.map(\.t), [20, 25, 30])
        XCTAssertFalse(notes[5].moving)
        XCTAssertTrue(notes[8].moving)
        XCTAssertEqual(notes.last?.distanceM ?? 0, 300, accuracy: 1)
        // no odometer (phone only): the GPS path, good fixes only
        let gps = (0...4).map { i -> RideSample in
            RideSample(t: Double(i) * 5, gpsSpeedKmh: 18, lat: 10 + Double(i) * 0.0002247, lon: -30, hAccM: i == 2 ? 80 : 5)
        }
        let g = SampleAnnotator.annotate(gps, stops: [])
        XCTAssertEqual(g[2].distanceM, g[1].distanceM, "a bad fix adds nothing")
        XCTAssertEqual(g.last?.distanceM ?? 0, 100, accuracy: 1)
    }
}
