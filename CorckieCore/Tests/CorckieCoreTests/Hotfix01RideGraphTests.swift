import XCTest
@testable import CorckieCore

/// Hotfix 01 (H1): on the ride graph a sideways pinch zooms time and an up-down pinch stretches the values; both coexist.
final class Hotfix01TimeZoomTests: XCTestCase {
    private let full: ClosedRange<Double> = 0...1_200

    func test_thePinchAxisFollowsTheFingers() {
        XCTAssertEqual(RideGraph.pinchAxis(dx: 200, dy: 40), .time, "fingers side by side: time")
        XCTAssertEqual(RideGraph.pinchAxis(dx: 30, dy: 180), .value, "fingers one above the other: values")
        XCTAssertEqual(RideGraph.pinchAxis(dx: -150, dy: 149), .time)
    }

    func test_aSidewaysPinchNarrowsTheWindowAroundTheFingers() {
        let w = RideGraph.timeZoomed(full, full: full, scale: 4, anchor: 0.5)
        XCTAssertEqual(w.upperBound - w.lowerBound, 300, accuracy: 0.001)
        XCTAssertEqual((w.lowerBound + w.upperBound) / 2, 600, accuracy: 0.001)
        let left = RideGraph.timeZoomed(full, full: full, scale: 2, anchor: 0)
        XCTAssertEqual(left, 0...600)
        XCTAssertTrue(RideGraph.isZoomed(w, full: full))
        XCTAssertFalse(RideGraph.isZoomed(full, full: full))
    }

    func test_theWindowStaysInsideTheRideAndNeverTooShort() {
        let tight = RideGraph.timeZoomed(full, full: full, scale: 1_000, anchor: 1)
        XCTAssertEqual(tight.upperBound - tight.lowerBound, RideGraph.minWindowS, accuracy: 0.001)
        XCTAssertEqual(tight.upperBound, 1_200, accuracy: 0.001)
        XCTAssertEqual(RideGraph.timeZoomed(300...600, full: full, scale: 0.01, anchor: 0.5), full, "pinching out ends at the whole ride")
    }

    func test_dragPansAndStopsAtTheEnds() {
        let w: ClosedRange<Double> = 300...600
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: -0.5), 450...750, "finger left: later")
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: 2), 0...300, "never before the start")
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: -9), 900...1_200, "never after the end")
    }

    func test_valueScaleCoexistsWithTheTimeWindow() {
        // made-up speed: 10 km/h for the first half, 30 km/h for the second
        let times = (0...1_200).map(Double.init)
        let line = GraphLine(series: .speed, times: times, values: times.map { $0 < 600 ? 10 + sin($0) : 30 + sin($0) })
        let early = RideGraph.scaledRange(line, factor: 1, within: 0...300)
        XCTAssertLessThan(early.upperBound, 15, "the auto-fit follows the visible window")
        let stretched = RideGraph.scaledRange(line, factor: 4, within: 0...300)
        XCTAssertLessThan(stretched.upperBound - stretched.lowerBound, early.upperBound - early.lowerBound)
        XCTAssertTrue(stretched.contains(10), "stretched around the visible data")
        XCTAssertEqual(RideGraph.scaledRange(line, factor: 1), RideGraph.range(line, within: 0...1_200), "no window: the whole ride as before")
    }
}

/// Hotfix 01 (H2): tap a selected chip again for its derived series, again for the base.
final class Hotfix01DerivedChipTests: XCTestCase {
    /// A made-up ride, one reading a second: speeding up, a climb, the battery going down (not a real place)
    private func data() -> RideLayerData {
        var pts: [SeriesPoint] = []
        for i in 0..<300 {
            let t = Double(i)
            let lat: Double = 10.0 + t * 5 / Geo.mPerDegLat
            let speed: Double = min(30.0, 5.0 + t / 4)
            let battery: Int = 80 - i / 30
            let alt: Double = i < 100 ? 10.0 : 10.0 + (t - 100) * 0.2
            pts.append(SeriesPoint(t: t, lat: lat, lon: 20.0, hAccM: 5, speedKmh: speed, batteryPct: battery,
                                   altM: alt, powerW: 300, tempC: 25))
        }
        return RideLayerData(points: pts, energy: EnergyTrack.build(pts), weather: [], rideStartMs: 1_790_000_000_000)
    }

    func test_theRowHasOnlyBaseChips() {
        let chips = GraphChips(available: RideGraph.available(data()))
        XCTAssertEqual(chips.on, [.speed])
        XCTAssertEqual(chips.row.first, .speed)
        XCTAssertFalse(chips.row.contains(.accel) || chips.row.contains(.incline) || chips.row.contains(.batteryPerKm), "derived series live on their base chip")
        XCTAssertTrue(chips.row.contains(.battery) && chips.row.contains(.height) && chips.row.contains(.power))
    }

    func test_speedAgainIsAcceleration_andBack() {
        var chips = GraphChips(available: RideGraph.available(data()))
        chips.tap(.speed)
        XCTAssertEqual(chips.shownSeries, [.accel])
        XCTAssertEqual(chips.label(.speed), "Speed \u{2192} Accel")
        XCTAssertEqual(chips.highlightedSeries.unit, "m/s\u{00B2}", "the axis follows the derived series")
        chips.tap(.speed)
        XCTAssertEqual(chips.shownSeries, [.speed])
        XCTAssertEqual(chips.label(.speed), "Speed")
    }

    func test_batteryAndHeightHaveTheirOwn() {
        var chips = GraphChips(available: RideGraph.available(data()))
        chips.tap(.battery)          // on, gets the axis
        chips.tap(.battery)          // again: per km
        XCTAssertEqual(chips.shown(.battery), .batteryPerKm)
        XCTAssertEqual(chips.label(.battery), "Battery \u{2192} per km")
        chips.tap(.height)
        chips.tap(.height)
        XCTAssertEqual(chips.shown(.height), .incline)
        XCTAssertEqual(chips.shownSeries, [.speed, .batteryPerKm, .incline])
        chips.tap(.speed)            // speed gets the axis, still speed
        XCTAssertEqual(chips.highlightedSeries, .speed)
        chips.tap(.power)
        chips.tap(.power)            // no derived series: off again
        XCTAssertFalse(chips.isOn(.power))
        chips.remove(.battery)
        XCTAssertEqual(chips.shownSeries, [.speed, .incline])
    }

    func test_theDerivedValuesAreTheDerivedLine() {
        let d = data()
        let accel = RideGraph.line(.accel, d)
        XCTAssertEqual(accel.value(at: 50) ?? 0, 0.25 / 3.6, accuracy: 0.01, "speeding up by 0.25 km/h a second")
        let incline = RideGraph.line(.incline, d)
        XCTAssertEqual(incline.value(at: 200) ?? 0, 4, accuracy: 0.6, "0.2 m per 5 m = 4 %")
    }
}
