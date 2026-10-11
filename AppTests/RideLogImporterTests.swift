import CorckieCore
import CorckieSim
import Foundation
import GRDB
import XCTest

/// Import ride logs through the real Recorder into a temporary database (anonymised fixtures only): the golden rides keep their
/// numbers, the ride is real (not simulated, real date, +03:00), marked as imported, and importing twice adds nothing.
final class RideLogImporterTests: XCTestCase {
    private let plus3: (Double) -> Int = { _ in 180 }
    private let saved = Date(timeIntervalSince1970: 1_790_000_000)   // synthetic "file date" for logs that have times of day only

    private func file(_ name: String, modified: Date? = nil) throws -> ImportFileText {
        let url = try XCTUnwrap(Bundle(for: RideLogImporterTests.self).url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
                                "fixture \(name) in the test bundle")
        return ImportFileText(name: name + ".csv", text: try String(contentsOf: url, encoding: .utf8), modified: modified)
    }

    private func ride2Files() throws -> [ImportFileText] {
        [try file("F5_ride2_nrf"), try file("F4_ride2_location"), try file("F4_ride2_barometer")]
    }

    func test_golden_ride1_nrfOnly_437Wh_16_3km_isARealRide() async throws {
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let report = try await RideLogImporter.run(db, files: [try file("F2_ride1_nrf", modified: saved)], build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(report.added, 1, report.text)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0, report.text)
        XCTAssertTrue(report.text.hasPrefix("Imported 1 ride · "), report.text)
        XCTAssertTrue(report.text.contains(" km · "), report.text)
        XCTAssertTrue(report.text.contains(" Wh"), report.text)
        let q = RideQueries(db)
        let id = try XCTUnwrap(report.rideIds.first)
        let ride = try XCTUnwrap(try q.ride(id: id))
        XCTAssertFalse(ride.isSimulated, "a real ride")
        XCTAssertEqual(ride.status, "ended")
        XCTAssertEqual(ride.kind, "ride")
        XCTAssertEqual(ride.utcOffsetMin, 180)
        XCTAssertEqual(ride.energyWhRaw ?? 0, 437, accuracy: 437 * 0.03)
        XCTAssertEqual((ride.distanceM ?? 0) / 1000, 16.3, accuracy: 0.15)
        XCTAssertLessThanOrEqual(ride.startAt, Int64(saved.timeIntervalSince1970 * 1000) + 60_000, "the ride's own day, not today")
        XCTAssertGreaterThan(ride.startAt, Int64(saved.timeIntervalSince1970 * 1000) - 86_400_000 - 60_000)
        XCTAssertEqual(RideLogImporter.importedIds(db), [id], "marked as imported")
        XCTAssertTrue(try q.openRides().isEmpty)
        XCTAssertEqual(try q.rides(includeDiscarded: true).count, 1)
        XCTAssertFalse(try q.chunks(rideId: id).isEmpty, "raw packets stored")
    }

    func test_golden_ride2_nrfWithSensorLogger_322Wh_13_7km_hasMapAndClimb() async throws {
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let report = try await RideLogImporter.run(db, files: try ride2Files(), build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(report.added, 1, report.text)
        let q = RideQueries(db)
        let id = try XCTUnwrap(report.rideIds.first)
        let ride = try XCTUnwrap(try q.ride(id: id))
        XCTAssertFalse(ride.isSimulated)
        XCTAssertEqual(ride.energyWhRaw ?? 0, 322, accuracy: 322 * 0.03)
        XCTAssertEqual((ride.distanceM ?? 0) / 1000, 13.7, accuracy: 0.15)
        XCTAssertTrue(ride.hasGps ?? false)
        // 2000-01-01 17:37 local at +03:00 = 14:37 UTC; the first move is a little later
        XCTAssertGreaterThan(ride.startAt, 946_737_000_000)
        XCTAssertLessThan(ride.startAt, 946_739_000_000)
        let samples = try q.samples(rideId: id)
        XCTAssertGreaterThan(samples.filter { $0.lat != nil }.count, 10, "GPS from the Sensor Logger file")
        XCTAssertGreaterThan(samples.filter { $0.altBaroM != nil }.count, 10, "barometer from the Sensor Logger file")
    }

    func test_importingTheSameFilesTwice_addsNothing() async throws {
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let files = try ride2Files()
        let first = try await RideLogImporter.run(db, files: files, build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(first.added, 1, first.text)
        let before = try db.rowCounts()
        let second = try await RideLogImporter.run(db, files: files, build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(second.added, 0, second.text)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertTrue(second.text.hasPrefix("Nothing new"), second.text)
        XCTAssertEqual(try db.rowCounts(), before, "not one row more")
        XCTAssertEqual(try RideQueries(db).rides(includeDiscarded: true).count, 1)
    }

    func test_twoRidesInOneImport_andRestoreStillSeesThem() async throws {
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let files = try ride2Files() + [try file("F2_ride1_nrf", modified: saved)]
        let report = try await RideLogImporter.run(db, files: files, build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(report.added, 2, report.text)
        XCTAssertTrue(report.text.hasPrefix("Imported 2 rides · "), report.text)
        XCTAssertEqual(RideLogImporter.importedIds(db).count, 2)
        // imported rides are real rides: Export everything carries them
        let export = try ExportAll.make(db, build: "test", nowMs: 0)
        XCTAssertEqual(export.rides.count, 2)
    }

    func test_c8Set_makesTheSameRide() async throws {
        // render the nRF + Sensor Logger pair as a 0.4 c8 set
        let log = try XCTUnwrap(try RideLogImport.build(files: try ride2Files(), utcOffsetMin: plus3).first)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ t: Double) -> String { iso.string(from: Date(timeIntervalSince1970: t)) }
        var packets = "time,step,app_state,bytes\n"
        for e in log.stream.scooter { if let b = e.bytes { packets += "\(stamp(e.t)),c8,open,\(Hex.string(b))\n" } }
        var location = "time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg\n"
        var baro = "time,relative_altitude_m,pressure_kpa\n"
        for e in log.stream.phone {
            if let f = e.fix {
                location += stamp(f.t) + String(format: ",%.7f,%.7f,%.2f,%.1f,%.1f,%.1f\n", f.lat, f.lon, f.speedMps, f.hAccM, f.altitudeM ?? 0, f.courseDeg)
            } else if let b = e.baro {
                baro += stamp(b.t) + String(format: ",%.3f,%.4f\n", b.relativeAltitudeM, b.pressureKPa ?? 0)
            }
        }
        let c8 = [ImportFileText(name: "c8-scooter-packets.csv", text: packets), ImportFileText(name: "c8-location.csv", text: location),
                  ImportFileText(name: "c8-barometer.csv", text: baro)]
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let report = try await RideLogImporter.run(db, files: c8, build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(report.added, 1, report.text)
        let ride = try XCTUnwrap(try RideQueries(db).ride(id: try XCTUnwrap(report.rideIds.first)))
        XCTAssertFalse(ride.isSimulated)
        XCTAssertEqual(ride.energyWhRaw ?? 0, 322, accuracy: 322 * 0.03)
        XCTAssertEqual((ride.distanceM ?? 0) / 1000, 13.7, accuracy: 0.15)
        XCTAssertEqual(ride.utcOffsetMin, 180)
        // the same ride from the nRF files is the same ride: nothing added
        let again = try await RideLogImporter.run(db, files: try ride2Files(), build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(again.added, 0, again.text)
        XCTAssertEqual(again.skipped, 1)
    }

    func test_unusableFiles_saySo_andAddNothing() async throws {
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let before = try db.rowCounts()
        do {
            _ = try await RideLogImporter.run(db, files: [ImportFileText(name: "notes.csv", text: "a,b\n1,2\n")], build: "test", utcOffsetMinAt: plus3)
            XCTFail("no scooter log")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No scooter log"))
        }
        // a log in which the scooter never moved makes no ride
        let still = "Timestamp,Source,Level,Line\n\"10:00:00.000\",\"Connected Device\",\"Normal\",\"Connected.\"\n\"10:00:20.000\",\"Connected Device\",\"Normal\",\"Disconnected.\"\n"
        let report = try await RideLogImporter.run(db, files: [ImportFileText(name: "empty.txt", text: still, modified: saved)], build: "test", utcOffsetMinAt: plus3)
        XCTAssertEqual(report.added, 0)
        XCTAssertTrue(report.text.contains("No ride") || report.text.contains("no ride"), report.text)
        XCTAssertEqual(try db.rowCounts(), before)
    }
}
