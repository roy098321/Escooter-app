import XCTest
@testable import CorckieCore

/// F-33: the five-button layer row, tap again for the derived view, stops as dots, honest legends.
final class LayerViewsTests: XCTestCase {
    /// A made-up straight ride, one reading a second (not a real place)
    private func ride(_ n: Int, speed: (Int) -> Double = { _ in 18 }, alt: ((Int) -> Double?)? = nil,
                      temp: ((Int) -> Double?)? = nil, battery: ((Int) -> Int?)? = nil, power: ((Int) -> Double?)? = nil) -> [SeriesPoint] {
        (0..<n).map { i in
            SeriesPoint(t: Double(i), lat: 10.0 + Double(i) * 5 / Geo.mPerDegLat, lon: 20.0, hAccM: 5, speedKmh: speed(i),
                        batteryPct: battery?(i), altM: alt?(i), powerW: power?(i), tempC: temp?(i))
        }
    }

    private func data(_ pts: [SeriesPoint], weather: [WeatherRow] = []) -> RideLayerData {
        RideLayerData(points: pts, energy: EnergyTrack.build(pts), weather: weather, rideStartMs: 1_790_000_000_000)
    }

    func testTapAgainFlipsToTheDerivedView() {
        var v = LayerView.default
        XCTAssertEqual(v.buttonLabel, "Speed")
        v = v.tapped(.speed)
        XCTAssertEqual(v.buttonLabel, "Steady")
        XCTAssertEqual(v.title, "Steadiness")
        v = v.tapped(.speed)
        XCTAssertEqual(v, LayerView(.speed))
        v = v.tapped(.hills)
        XCTAssertEqual(v.title, "Height", "Hills opens at Height, the new default")
        XCTAssertEqual(v.tapped(.hills).buttonLabel, "Grade")
        XCTAssertEqual(LayerView(.wind, deep: true).buttonLabel, "Wind cost")
        XCTAssertEqual(LayerView(.battery, deep: true).buttonLabel, "Drain")
        XCTAssertEqual(LayerView(.temp, deep: true).buttonLabel, "Heating")
        XCTAssertEqual(LayerView(.temp).title, "Controller temp", "labelled honestly as the controller's temperature")
        // another button always opens at its base view
        XCTAssertEqual(LayerView(.speed, deep: true).tapped(.battery), LayerView(.battery))
        XCTAssertTrue(LayerView(.speed, deep: true).showsStops)
        XCTAssertFalse(LayerView(.hills).showsStops)
    }

    func testButtonsOnlyForWhatTheRideHas() {
        XCTAssertEqual(LayerViews.available(data(ride(100))), [.speed, .wind])
        let full = ride(100, alt: { Double($0) }, temp: { 30 + Double($0) / 10 }, battery: { 80 - $0 / 50 })
        XCTAssertEqual(LayerViews.available(data(full)), MapLayer.allCases)
    }

    func testSteadinessIsCalmWhereSpeedIsHeld() {
        // held at 20 km/h, then a hard swing between 10 and 30 every 5 s
        let pts = ride(300, speed: { $0 < 150 ? 20 : ($0 / 5 % 2 == 0 ? 10 : 30) })
        let s = LayerViews.stretches(LayerView(.speed, deep: true), data(pts))
        XCTAssertFalse(s.isEmpty)
        let calm = s.filter { $0.t < 120 }.map(\.value), hot = s.filter { $0.t > 180 }.map(\.value)
        XCTAssertLessThan(calm.max() ?? 9, 0.3)
        XCTAssertGreaterThan(hot.reduce(0, +) / Double(max(1, hot.count)), 1)
    }

    func testHeightBatteryAndTempFollowTheReadings() {
        let pts = ride(300, alt: { 10 + Double($0) / 10 }, temp: { 30 + Double($0) / 20 }, battery: { 80 - $0 / 30 }, power: { _ in 300 })
        let d = data(pts)
        let height = LayerViews.stretches(LayerView(.hills), d)
        XCTAssertLessThan(height.first?.value ?? 99, height.last?.value ?? 0)
        let scale = LayerViews.scale(LayerView(.hills), stretches: height, energy: d.energy, colourBlind: false)
        XCTAssertEqual(scale.title, "Height")
        XCTAssertTrue(scale.low.hasSuffix(" m"))
        let battery = LayerViews.stretches(LayerView(.battery), d)
        XCTAssertGreaterThan(battery.first?.value ?? 0, battery.last?.value ?? 99)
        let drain = LayerViews.stretches(LayerView(.battery, deep: true), d)
        XCTAssertFalse(drain.isEmpty)
        XCTAssertTrue(drain.allSatisfy { $0.value > 0 })
        let heating = LayerViews.stretches(LayerView(.temp, deep: true), d)
        XCTAssertFalse(heating.isEmpty)
        // 1 °C every 20 s = 3 °C per minute
        XCTAssertEqual(heating.last?.value ?? 0, 3, accuracy: 0.5)
        XCTAssertEqual(LayerViews.scale(LayerView(.temp), stretches: LayerViews.stretches(LayerView(.temp), d), energy: d.energy,
                                        colourBlind: false).title, "Controller temp")
    }

    func testWindShareHeadwindCostsTailwindSaves() {
        XCTAssertEqual(LayerViews.windShare(speedKmh: 25, headwindKmh: 0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(LayerViews.windShare(speedKmh: 25, headwindKmh: 15), 0.3)
        XCTAssertLessThan(LayerViews.windShare(speedKmh: 25, headwindKmh: -15), -0.3)
        XCTAssertNotNil(LayerViews.windCostNote([ValueStretch(a: GeoPoint(lat: 10, lon: 20), b: GeoPoint(lat: 10.02, lon: 20), t: 0, value: 0.5)]))
        XCTAssertNil(LayerViews.windCostNote([]))
    }

    func testStopsAreDotsSizedByTime() {
        // ride, a 90 s stop, ride, a 10 s pause (not a stop), ride
        let pts = ride(400, speed: { (100..<190).contains($0) || (300..<310).contains($0) ? 0 : 18 })
        let stops = LayerViews.stops(pts)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.durationS ?? 0, 90, accuracy: 1)
        XCTAssertEqual(stops.first?.text, "Stopped 2 min")
        // standing at the very start is not a stop
        XCTAssertEqual(LayerViews.stops(ride(100, speed: { $0 < 40 ? 0 : 18 })).count, 0)
    }

    func testHintShowsTheFirstFewTimes() {
        XCTAssertTrue(LayerViews.showsHint(timesShown: 0))
        XCTAssertFalse(LayerViews.showsHint(timesShown: LayerViews.hintTimes))
        XCTAssertEqual(LayerViews.hintText, "Tap layer for deeper view")
    }
}
