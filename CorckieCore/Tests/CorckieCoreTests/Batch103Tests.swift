import XCTest
@testable import CorckieCore

/// Batch 3 (103.081126.00). Made-up readings only.
final class Batch103Tests: XCTestCase {

    private func frame(_ t: Double, speed: Double? = 0, pct: Int? = 80, odo: Double? = 100, tempC: Double? = nil,
                       noTemp: Bool = false, current: Double? = 0) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = speed
        f.batteryPct = pct
        f.odometerKm = odo
        f.voltage = 50
        f.temperatureC = tempC
        f.temperatureNoReading = noTemp
        f.currentA = current
        return f
    }

    // MARK: B73 · nothing from an earlier connection is a reading of this one (every metric)

    func testReconnectClearsEveryScooterValue() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 0, pct: 62, odo: 1_370.4, tempC: 87, current: 0)), at: 1)
        XCTAssertEqual(e.temperatureC, 87)
        e.handle(.disconnected, at: 2)
        e.handle(.connected, at: 50_000)
        XCTAssertNil(e.temperatureC, "temperature")
        XCTAssertNil(e.batteryPct, "battery %")
        XCTAssertNil(e.odometerKm, "odometer")
        XCTAssertNil(e.speedKmh, "speed")
        XCTAssertNil(e.currentA, "current")
        XCTAssertNil(e.powerW, "power")
    }

    func testBootFrameWithoutTemperatureNeverBringsBackTheOldOne() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, tempC: 87)), at: 1)
        // same connection: the scooter says "no reading yet" (0xFFFF) → cleared, not kept
        e.handle(.frame(frame(2, tempC: nil, noTemp: true)), at: 2)
        XCTAssertNil(e.temperatureC)
        // a frame that simply has no packet B value keeps this connection's value
        e.handle(.frame(frame(3, tempC: 60)), at: 3)
        e.handle(.frame(frame(4, tempC: nil, noTemp: false)), at: 4)
        XCTAssertEqual(e.temperatureC, 60)
    }

    func testFrameAssemblerMarksTheNoReadingSentinel() {
        var a = FrameAssembler()
        let b: [UInt8] = [0xFF, 0xFF, 0x96, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let f = a.ingest(b, at: 0)
        XCTAssertEqual(f?.temperatureNoReading, true)
        XCTAssertNil(f?.temperatureC)
        let real: [UInt8] = [0x3C, 0x00, 0x96, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let g = a.ingest(real, at: 1)
        XCTAssertEqual(g?.temperatureNoReading, false)
        XCTAssertEqual(g?.temperatureC, 60)
    }

    func testRideKeepsItsLastBatteryThroughAReconnect() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 15, pct: 70, current: 5)), at: 1)
        XCTAssertTrue(e.rideActive)
        e.handle(.disconnected, at: 2)
        e.handle(.connected, at: 3)
        e.handle(.frame(frame(4, speed: 15, pct: nil, current: 5)), at: 4)   // settling: no % yet
        XCTAssertNil(e.batteryPct)
        XCTAssertEqual(e.ride?.lastBatteryPct, 70, "the ride's own record stays")
    }

    // MARK: B74 · 25 and 50 m places

    func testSmallPlaceCircles() {
        XCTAssertEqual(Array(PlaceListBuilder.radiusChoices.prefix(2)), [25, 50])
        let p = PlaceInfo(id: "p", point: GeoPoint(lat: 0, lon: 0), radiusM: 25)
        XCTAssertTrue(PlaceMatching.reaches(p, GeoPoint(lat: 0.00018, lon: 0), tripLengthM: 5_000), "20 m: inside")
        XCTAssertFalse(PlaceMatching.reaches(p, GeoPoint(lat: 0.00036, lon: 0), tripLengthM: 5_000), "40 m: outside")
        XCTAssertEqual(TripRules.widenRadius(endDistancesM: [30, 45], radiusM: 25, choices: PlaceListBuilder.radiusChoices), 50)
        XCTAssertEqual(TripRules.widenRadius(endDistancesM: [60, 90], radiusM: 50, choices: PlaceListBuilder.radiusChoices), 100)
    }

    // MARK: B75 · fuel price: 3 digits, the point goes in by itself

    func testFuelPriceEntry() {
        XCTAssertEqual(FuelPriceEntry.format("8"), "8")
        XCTAssertEqual(FuelPriceEntry.format("82"), "8.2")
        XCTAssertEqual(FuelPriceEntry.format("827"), "8.27")
        XCTAssertEqual(FuelPriceEntry.format("8270"), "8.27", "a 4th digit is ignored")
        XCTAssertEqual(FuelPriceEntry.format("8.27"), "8.27", "pasted with a point")
        XCTAssertEqual(FuelPriceEntry.format(""), "")
        XCTAssertNil(FuelPriceEntry.value("8.2"), "not all 3 digits yet")
        XCTAssertEqual(FuelPriceEntry.value("8.27") ?? 0, 8.27, accuracy: 1e-9)
        XCTAssertNil(FuelPriceEntry.value("0.00"))
    }

    // MARK: B76 · the ride screen waits for the real ride

    func testWheelingOutKeepsTheRideInTheBackground() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        // scooter on, wheeled out at walking pace with no motor power for 20 s
        for t in stride(from: 1.0, through: 20, by: 0.5) {
            e.handle(.frame(frame(t, speed: 3, current: 0)), at: t)
        }
        XCTAssertTrue(e.rideActive, "recording quietly in the background (B62)")
        XCTAssertFalse(e.liveInput(at: 20).ridingEngaged, "no ride screen yet")
        // rides off: motor power and 12 km/h for a few seconds
        for t in stride(from: 20.5, through: 30, by: 0.5) {
            e.handle(.frame(frame(t, speed: 12, current: 6)), at: t)
        }
        XCTAssertTrue(e.liveInput(at: 30).ridingEngaged, "the real ride started: the screen opens")
    }

    func testStartByHandEngagesAtOnce() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 0)), at: 1)
        e.handle(.startPressed, at: 2)
        XCTAssertTrue(e.liveInput(at: 2).ridingEngaged)
    }

    /// The owner's 3 Nov case: 87 °C from yesterday, scooter on, waiting > 20 s before setting off → no engine line.
    func testNoEngineLineBeforeTheMotorRan() {
        var d = V09Director()
        var said: [V09Message] = []
        for t in stride(from: 0.0, through: 60, by: 1) {
            said += d.update(V09Input(t: t, pct: 98, tempC: 87, rideKm: 0, speedKmh: 0, currentA: 0))
        }
        XCTAssertFalse(said.contains { $0.kind == "hot" || $0.kind == "overheat" || $0.line.hasPrefix("Engine") }, said.map(\.line).joined())
        // the motor pushes, the reading stays hot for 20 s → said once
        for t in stride(from: 61.0, through: 90, by: 1) {
            said += d.update(V09Input(t: t, pct: 97, tempC: 87, rideKm: 0.2, speedKmh: 20, currentA: 6))
        }
        XCTAssertEqual(said.filter { $0 == .engineHot(c: 87) }.count, 1)
    }
}
