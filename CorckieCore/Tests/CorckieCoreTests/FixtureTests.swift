import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// P3_DILEMMAS D1 S123: fixtures enter only through Tools/anonymise.py.
/// These tests refuse any fixture that isn't anonymised, and check every reader on the P2 logs.
final class FixtureTests: XCTestCase {
    /// The fake box the anonymiser moves every track into (open ocean, Atlantic).
    static let fakeLat = 9.5...10.5
    static let fakeLon = -30.5 ... -29.5

    func test_D1_everyFixtureCarriesTheAnonymisedHeader() throws {
        let files = Fixtures.all(withExtension: "csv")
        XCTAssertGreaterThanOrEqual(files.count, 6)
        for file in files {
            let first = try String(contentsOf: file, encoding: .utf8).prefix(40)
            XCTAssertTrue(first.hasPrefix("# corckie-fixture v1"), "\(file.lastPathComponent) didn't come through Tools/anonymise.py")
        }
    }

    func test_D1_noRealDatesInFixtures() throws {
        for file in Fixtures.all(withExtension: "csv") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for year in 2001...2099 {
                XCTAssertFalse(text.contains("\(year)-0") || text.contains("\(year)-1"),
                               "\(file.lastPathComponent) has a real date (\(year))")
            }
        }
    }

    func test_D1_everyCoordinateIsInTheFakeBox() throws {
        let merged = try LogReader.mergedSamples(Fixtures.text("F3_ride2_merged.csv"))
        let fixes = try LogReader.sensorLoggerLocation(Fixtures.text("F4_ride2_location.csv"))
        var count = 0
        for s in merged {
            guard let lat = s.lat, let lon = s.lon else { continue }
            XCTAssertTrue(Self.fakeLat.contains(lat) && Self.fakeLon.contains(lon), "real coordinate in F3: \(lat), \(lon)")
            count += 1
        }
        for f in fixes {
            XCTAssertTrue(Self.fakeLat.contains(f.lat) && Self.fakeLon.contains(f.lon), "real coordinate in F4: \(f.lat), \(f.lon)")
        }
        XCTAssertGreaterThan(count, 1000)
        XCTAssertGreaterThan(fixes.count, 1000)
    }

    func test_readers_F1_p2LabLog() throws {
        let log = try LogReader.scooterLog(Fixtures.text("F1_p2lab_2oct.csv"))
        XCTAssertEqual(log.format, .packetLog)
        XCTAssertEqual(log.packets.count, 2298)
        XCTAssertEqual(log.startTimeOfDayS ?? 0, 8 * 3600 + 17 * 60 + 30.072, accuracy: 0.01)
        XCTAssertGreaterThan(log.durationS, 20 * 60)
    }

    func test_readers_F2_nrfRide1() throws {
        let log = try LogReader.scooterLog(Fixtures.text("F2_ride1_nrf.csv"))
        XCTAssertEqual(log.format, .nrfConnect)
        XCTAssertEqual(log.packets.count, 7994)
        XCTAssertEqual(log.events.first?.event, .connected)
        XCTAssertEqual(log.events.last?.event, .disconnected)
    }

    func test_readers_F3_F4_F5() throws {
        let merged = try LogReader.mergedSamples(Fixtures.text("F3_ride2_merged.csv"))
        XCTAssertEqual(merged.count, 1810)
        XCTAssertEqual(merged.last?.t ?? 0, 1809, accuracy: 1)
        let baro = try LogReader.sensorLoggerBarometer(Fixtures.text("F4_ride2_barometer.csv"))
        XCTAssertGreaterThan(baro.count, 1500)
        let ride2 = try LogReader.scooterLog(Fixtures.text("F5_ride2_nrf.csv"))
        XCTAssertEqual(ride2.packets.count, 6248)
    }

    func test_readers_csvQuotes() {
        XCTAssertEqual(LogReader.csvFields("a,\"b,c\",\"d \"\"x\"\"\",e"), ["a", "b,c", "d \"x\"", "e"])
        XCTAssertEqual(LogReader.csvFields("a,,b"), ["a", "", "b"])
    }

    func test_readers_wrongFormatIsRefused() {
        XCTAssertThrowsError(try LogReader.scooterLog("hello,world\n1,2"))
        XCTAssertThrowsError(try LogReader.mergedSamples("time,step,app_state,bytes\n"))
    }

    func test_encoder_roundTripsThroughTheRealDecoder() {
        var v = PacketEncoder.Values()
        v.speedKmh = 23.8
        v.voltage = 51.23
        v.odometerKm = 603.4
        v.batteryPct = 64
        v.brake = true
        v.headlight = true
        v.temperatureC = 41
        v.currentA = 12.34
        guard case .a(let a) = Decoder.decode(PacketEncoder.packetA(v)),
              case .b(let b) = Decoder.decode(PacketEncoder.packetB(v)) else { return XCTFail("decode failed") }
        XCTAssertEqual(a.speedKmh, 23.8, accuracy: T.t01WheelKmhPerUnit)
        XCTAssertEqual(a.voltage, 51.23, accuracy: 0.001)
        XCTAssertEqual(a.odometerKm, 603.4, accuracy: 0.001)
        XCTAssertEqual(a.batteryPct, 64)
        XCTAssertTrue(a.brake)
        XCTAssertTrue(a.headlight)
        XCTAssertEqual(b.temperatureC, 41)
        XCTAssertEqual(b.currentA, 12.34, accuracy: 0.001)
        v.temperatureC = nil
        guard case .b(let b2) = Decoder.decode(PacketEncoder.packetB(v)) else { return XCTFail("decode failed") }
        XCTAssertNil(b2.temperatureC)
    }
}
