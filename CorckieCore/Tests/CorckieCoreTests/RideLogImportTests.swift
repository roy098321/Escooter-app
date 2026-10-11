import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// Import ride logs: the c8 set of 0.4 and an nRF Connect log with Sensor Logger files, recognised, paired and put on the real clock.
/// Anonymised fixtures only (F1, F2, F4, F5; their dates are 2000-01-01 and their places are in the open sea).
final class RideLogImportTests: XCTestCase {
    private let plus3: (Double) -> Int = { _ in 180 }

    private func file(_ name: String, modified: Date? = nil) throws -> ImportFileText {
        ImportFileText(name: name, text: try Fixtures.text(name), modified: modified)
    }

    private func iso(_ t: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// 2000-01-01 17:37:31.443 at +03:00
    private let ride2Start = 946_684_800.0 + 14 * 3600 + 37 * 60 + 31.443

    // MARK: Recognising

    func test_kind_recognisesEveryFormat_byTheFirstLine() throws {
        XCTAssertEqual(RideLogImport.kind(of: try Fixtures.text("F1_p2lab_2oct.csv")), .c8Packets)
        XCTAssertEqual(RideLogImport.kind(of: try Fixtures.text("F5_ride2_nrf.csv")), .nrf)
        XCTAssertEqual(RideLogImport.kind(of: try Fixtures.text("F4_ride2_location.csv")), .sensorLoggerLocation)
        XCTAssertEqual(RideLogImport.kind(of: try Fixtures.text("F4_ride2_barometer.csv")), .sensorLoggerBarometer)
        XCTAssertEqual(RideLogImport.kind(of: "time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg\n"), .c8Location)
        XCTAssertEqual(RideLogImport.kind(of: "time,relative_altitude_m,pressure_kpa\n"), .c8Barometer)
        XCTAssertEqual(RideLogImport.kind(of: "\u{FEFF}time,step,app_state,bytes\n"), .c8Packets)
        XCTAssertEqual(RideLogImport.kind(of: "a,b,c\n1,2,3\n"), .unknown)
        XCTAssertEqual(RideLogImport.kind(of: ""), .unknown)
    }

    func test_noScooterLog_isSaidPlainly() throws {
        XCTAssertThrowsError(try RideLogImport.build(files: [try file("F4_ride2_location.csv")], utcOffsetMin: plus3)) {
            XCTAssertEqual($0 as? RideLogImportError, .noScooterLog)
        }
    }

    // MARK: c8 packet log (the 0.4 format has the date in every row)

    func test_c8Packets_keepTheirRealTimestamps() throws {
        let logs = try RideLogImport.build(files: [try file("F1_p2lab_2oct.csv")], utcOffsetMin: plus3)
        XCTAssertEqual(logs.count, 1)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.source, "c8")
        XCTAssertEqual(log.startEpoch, 946_684_800 + 8 * 3600 + 17 * 60 + 30.072, accuracy: 0.001)
        XCTAssertEqual(log.utcOffsetMin, 180)
        XCTAssertEqual(log.stream.scooter.first?.t ?? 0, log.startEpoch, accuracy: 0.001)
        XCTAssertGreaterThan(log.stream.scooter.count, 1_000)
    }

    // MARK: nRF Connect + Sensor Logger

    func test_nrfWithSensorLogger_isPaired_andTheDayComesFromTheSensorLoggerClock() throws {
        let logs = try RideLogImport.build(files: [try file("F5_ride2_nrf.csv"), try file("F4_ride2_location.csv"),
                                                   try file("F4_ride2_barometer.csv")], utcOffsetMin: plus3)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(log.source, "nRF Connect")
        XCTAssertEqual(log.fileNames, ["F5_ride2_nrf.csv", "F4_ride2_location.csv", "F4_ride2_barometer.csv"])
        XCTAssertEqual(log.startEpoch, ride2Start, accuracy: 0.01)
        XCTAssertEqual(log.utcOffsetMin, 180)
        XCTAssertGreaterThan(log.stream.phone.filter { $0.fix != nil }.count, 1_800)
        XCTAssertGreaterThan(log.stream.phone.filter { $0.baro != nil }.count, 1_500)
        // fixes sit on the scooter's clock: first fix a few seconds after the log's first row, sorted
        let firstFix = try XCTUnwrap(log.stream.phone.first { $0.fix != nil })
        XCTAssertEqual(firstFix.t - log.startEpoch, 11.5, accuracy: 1.0)
        XCTAssertEqual(firstFix.fix?.t ?? 0, firstFix.t, accuracy: 1e-6)
        XCTAssertEqual(log.stream.phone.map(\.t), log.stream.phone.map(\.t).sorted())
        XCTAssertTrue(log.notes.isEmpty)
    }

    func test_nrfAlone_takesTheDayFromTheFileDate_orAsks() throws {
        XCTAssertThrowsError(try RideLogImport.build(files: [try file("F5_ride2_nrf.csv")], utcOffsetMin: plus3)) {
            XCTAssertEqual($0 as? RideLogImportError, .needsDate("F5_ride2_nrf.csv"))
        }
        // saved in the evening of 5 Oct 2026 (UTC 18:00): the ride was that day, 17:37 local
        let saved = Date(timeIntervalSince1970: 1_790_000_000)   // synthetic
        let logs = try RideLogImport.build(files: [try file("F5_ride2_nrf.csv", modified: saved)], utcOffsetMin: plus3)
        let log = try XCTUnwrap(logs.first)
        XCTAssertLessThanOrEqual(log.startEpoch, saved.timeIntervalSince1970 + 60)
        XCTAssertGreaterThan(log.startEpoch, saved.timeIntervalSince1970 - 86_400 - 60)
        let local = log.startEpoch + 3 * 3600
        XCTAssertEqual(local.truncatingRemainder(dividingBy: 86_400), 17 * 3600 + 37 * 60 + 31.443, accuracy: 0.01, "time of day kept")
        XCTAssertTrue(log.notes.joined().contains("day taken from"))
        XCTAssertTrue(log.stream.phone.isEmpty)
    }

    func test_sensorLoggerOfAnotherRide_isNotPaired() throws {
        // F4 was recorded with ride 2 (17:37); ride 1 (F2) was at 15:47
        let logs = try RideLogImport.build(files: [try file("F2_ride1_nrf.csv", modified: Date(timeIntervalSince1970: 1_790_000_000)),
                                                   try file("F4_ride2_location.csv")], utcOffsetMin: plus3)
        let log = try XCTUnwrap(logs.first)
        XCTAssertTrue(log.stream.phone.isEmpty)
        XCTAssertTrue(log.notes.joined().contains("F4_ride2_location.csv"))
    }

    func test_twoRidesInOneGo_comeOutInTimeOrder() throws {
        let logs = try RideLogImport.build(files: [try file("F5_ride2_nrf.csv"), try file("F4_ride2_location.csv"),
                                                   try file("F2_ride1_nrf.csv", modified: Date(timeIntervalSince1970: 1_790_000_000))],
                                           utcOffsetMin: plus3)
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs.map(\.startEpoch), logs.map(\.startEpoch).sorted())
    }

    // MARK: c8 round trip: render the pair as a 0.4 c8 set and read it back

    private func c8Files(of log: ImportedRideLog) -> [ImportFileText] {
        var packets = "time,step,app_state,bytes\n"
        for e in log.stream.scooter { if let b = e.bytes { packets += "\(iso(e.t)),c8,open,\(Hex.string(b))\n" } }
        var location = "time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg\n"
        var baro = "time,relative_altitude_m,pressure_kpa\n"
        for e in log.stream.phone {
            if let f = e.fix {
                location += iso(f.t) + String(format: ",%.7f,%.7f,%.2f,%.1f,%.1f,%.1f\n", f.lat, f.lon, f.speedMps, f.hAccM, f.altitudeM ?? 0, f.courseDeg)
            } else if let b = e.baro {
                baro += iso(b.t) + String(format: ",%.3f,%.4f\n", b.relativeAltitudeM, b.pressureKPa ?? 0)
            }
        }
        return [ImportFileText(name: "c8-scooter-packets.csv", text: packets), ImportFileText(name: "c8-location.csv", text: location),
                ImportFileText(name: "c8-barometer.csv", text: baro)]
    }

    func test_c8Set_roundTrip_sameRideAsTheNrfPair() throws {
        let nrf = try XCTUnwrap(try RideLogImport.build(files: [try file("F5_ride2_nrf.csv"), try file("F4_ride2_location.csv"),
                                                                try file("F4_ride2_barometer.csv")], utcOffsetMin: plus3).first)
        let c8 = try XCTUnwrap(try RideLogImport.build(files: c8Files(of: nrf), utcOffsetMin: plus3).first)
        XCTAssertEqual(c8.source, "c8")
        XCTAssertEqual(c8.fileNames, ["c8-scooter-packets.csv", "c8-location.csv", "c8-barometer.csv"])
        XCTAssertEqual(c8.stream.scooter.count, nrf.stream.scooter.filter { $0.bytes != nil }.count)
        XCTAssertEqual(c8.startEpoch, nrf.stream.scooter.first { $0.bytes != nil }?.t ?? 0, accuracy: 0.002)
        XCTAssertEqual(c8.stream.phone.filter { $0.fix != nil }.count, nrf.stream.phone.filter { $0.fix != nil }.count)
        XCTAssertEqual(c8.stream.phone.filter { $0.baro != nil }.count, nrf.stream.phone.filter { $0.baro != nil }.count)
        let a = try XCTUnwrap(nrf.stream.phone.compactMap(\.fix).first), b = try XCTUnwrap(c8.stream.phone.compactMap(\.fix).first)
        XCTAssertEqual(a.lat, b.lat, accuracy: 1e-6)
        XCTAssertEqual(a.lon, b.lon, accuracy: 1e-6)
        XCTAssertEqual(a.t, b.t, accuracy: 0.002)
        // a c8 location file of another time is left out
        let early = ImportFileText(name: "c8-location.csv", text: "time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg\n2001-01-01T00:00:00.000Z,10.0,-30.0,1.0,5.0,10.0,0.0\n")
        let alone = try XCTUnwrap(try RideLogImport.build(files: [c8Files(of: nrf)[0], early], utcOffsetMin: plus3).first)
        XCTAssertTrue(alone.stream.phone.isEmpty)
    }

    // MARK: Golden values through the import streams

    private func totals(_ log: ImportedRideLog) -> (wh: Double, km: Double) {
        var p = ScooterPipeline()
        p.handle(log.stream.scooter)
        return (p.totals.energyWhRaw, p.totals.distanceKm)
    }

    func test_golden_ride1_viaC8andNrf_437Wh_16_3km() throws {
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let nrf = try XCTUnwrap(try RideLogImport.build(files: [try file("F2_ride1_nrf.csv", modified: saved)], utcOffsetMin: plus3).first)
        XCTAssertEqual(totals(nrf).wh, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(totals(nrf).km, 16.3, accuracy: 0.05)
        let c8 = try XCTUnwrap(try RideLogImport.build(files: c8Files(of: nrf), utcOffsetMin: plus3).first)
        XCTAssertEqual(totals(c8).wh, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(totals(c8).km, 16.3, accuracy: 0.05)
    }

    func test_golden_ride2_viaNrfAndSensorLogger_322Wh_13_7km() throws {
        let nrf = try XCTUnwrap(try RideLogImport.build(files: [try file("F5_ride2_nrf.csv"), try file("F4_ride2_location.csv"),
                                                                try file("F4_ride2_barometer.csv")], utcOffsetMin: plus3).first)
        XCTAssertEqual(totals(nrf).wh, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(totals(nrf).km, 13.7, accuracy: 0.05)
    }

    // MARK: The recorder's input list

    func test_inputs_areOnTheRealClock_withATickEverySecond() throws {
        let log = try XCTUnwrap(try RideLogImport.build(files: [try file("F5_ride2_nrf.csv"), try file("F4_ride2_location.csv")], utcOffsetMin: plus3).first)
        let inputs = log.inputs()
        XCTAssertGreaterThan(inputs.first?.t ?? 0, 946_000_000)
        XCTAssertEqual(inputs.map { $0.t }, inputs.map { $0.t }.sorted())
        let ticks = inputs.filter { $0.input == .tick }.count
        XCTAssertGreaterThan(ticks, 1_800 + 1_000)
        XCTAssertGreaterThan(inputs.filter { if case .fix = $0.input { return true } else { return false } }.count, 1_800)
    }
}
