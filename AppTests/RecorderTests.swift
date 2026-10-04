import CorckieCore
import CorckieSim
import Foundation
import XCTest

/// M1-09: the real Recorder actor end to end on the fake scooter, into a temporary database (TESTING §5: the real
/// database is never opened). Rides 1 and 2 reproduce 437 Wh / 16.3 km and 322 Wh / 13.7 km from what was stored;
/// a kill mid-ride resumes (young) or is recovered at its last sample (old), SC-14.
final class RecorderTests: XCTestCase {
    /// 2026-09-20 as the base of the fixture clock (epoch seconds)
    private let epochOffset = 1_790_000_000.0

    private func stream(_ id: String, _ file: String) throws -> SimStream {
        let url = try XCTUnwrap(Bundle(for: RecorderTests.self).url(forResource: file, withExtension: "csv", subdirectory: "Fixtures"),
                                "fixture \(file) in the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == id })
        return SimStream(scooter: try sim.events(from: text), phone: [])
    }

    private func recorder(_ db: AppDatabase?, stateURL: URL) -> Recorder {
        Recorder(database: db, simulated: true, build: "test", stateURL: stateURL, epochOffset: epochOffset)
    }

    func test_golden_rides1and2_throughTheRecorder_intoATemporaryDatabase() async throws {
        for (id, file, wh, km) in [("F2", "F2_ride1_nrf", 437.0, 16.3), ("F5", "F5_ride2_nrf", 322.0, 13.7)] {
            let db = try AppDatabase.openTemporary(build: "test")
            defer { db.discardTemporary() }
            let stateURL = Recorder.stateURL(for: db)
            let rec = recorder(db, stateURL: stateURL)
            await rec.process(RecorderRunner.inputs(try stream(id, file)))
            let ids = await rec.closedRideIds
            let errors = await rec.writeErrors
            XCTAssertEqual(errors, [], id)
            XCTAssertEqual(ids.count, 1, id)
            let rideId = try XCTUnwrap(ids.first, id)
            let q = RideQueries(db)
            let ride = try XCTUnwrap(try q.ride(id: rideId), id)
            XCTAssertEqual(ride.status, "ended", id)
            XCTAssertEqual(ride.endReason, "scooterOff", id)
            XCTAssertEqual(ride.kind, "ride", id)
            XCTAssertTrue(ride.isSimulated, id)
            XCTAssertEqual(ride.energyWhRaw ?? 0, wh, accuracy: wh * 0.03, id)
            XCTAssertEqual((ride.distanceM ?? 0) / 1000, km, accuracy: 0.15, id)
            XCTAssertGreaterThan(ride.topSpeedMps ?? 0, 30 / 3.6, id)
            XCTAssertGreaterThan(try q.sampleCount(rideId: rideId), 100, id)
            XCTAssertFalse(try q.chunks(rideId: rideId).isEmpty, "\(id): raw packets stored")
            XCTAssertEqual(try q.chunks(rideId: rideId).first?.codec, "zlib-v1", id)
            XCTAssertEqual(try q.stops(rideId: rideId).count, ride.stops ?? -1, "\(id): stop rows = stop count")
            XCTAssertTrue(try q.openRides().isEmpty, "\(id): nothing left recording")
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path), "\(id): state saved for recovery")
        }
    }

    /// M1-15 / d8: the simulator's Recorder writes only into its own temporary database; a separate (stand-in real)
    /// database keeps every row count, and everything the simulation stored is marked simulated.
    func test_d8_simulatedRun_keepsTheRealDatabaseApart() async throws {
        let real = try AppDatabase.openTemporary(build: "test")
        let simDb = try AppDatabase.openTemporary(build: "test")
        defer { real.discardTemporary(); simDb.discardTemporary() }
        let before = try real.rowCounts()
        let rec = recorder(simDb, stateURL: Recorder.stateURL(for: simDb))
        await rec.process(RecorderRunner.inputs(try stream("F5", "F5_ride2_nrf")))
        XCTAssertEqual(try real.rowCounts(), before, "the real database is untouched")
        XCTAssertNotEqual(real.url, simDb.url)
        XCTAssertNotEqual(Recorder.stateURL(for: real), Recorder.stateURL(for: simDb))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recorder.stateURL(for: real).path))
        XCTAssertTrue(try RideQueries(real).rides(includeDiscarded: true).isEmpty)
        let simRides = try RideQueries(simDb).rides(includeDiscarded: true)
        XCTAssertEqual(simRides.count, 1)
        XCTAssertTrue(simRides.allSatisfy(\.isSimulated), "every simulated ride is marked")
    }

    func test_SC14_killMidRide_young_resumes_sameRide() async throws {
        let inputs = RecorderRunner.inputs(try stream("F5", "F5_ride2_nrf"))
        let killAt = (inputs.first?.t ?? 0) + 900
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let stateURL = Recorder.stateURL(for: db)
        let first = recorder(db, stateURL: stateURL)
        await first.process(inputs.filter { $0.t < killAt })
        // killed: the actor is gone, only the database and the state file remain
        let back = killAt + 3
        let second = recorder(nil, stateURL: stateURL)
        await second.attach(db, now: back)
        await second.process(inputs.filter { $0.t >= back })
        let ids = await second.closedRideIds
        XCTAssertEqual(ids.count, 1)
        let q = RideQueries(db)
        XCTAssertEqual(try q.rides(includeDiscarded: true).count, 1, "the same ride went on")
        let ride = try XCTUnwrap(try q.ride(id: try XCTUnwrap(ids.first)))
        XCTAssertEqual(ride.status, "ended")
        XCTAssertEqual(ride.energyWhRaw ?? 0, 322, accuracy: 322 * 0.05)
        XCTAssertEqual((ride.distanceM ?? 0) / 1000, 13.7, accuracy: 0.15)
    }

    func test_SC14_killMidRide_old_isRecovered_atItsLastSample() async throws {
        let inputs = RecorderRunner.inputs(try stream("F5", "F5_ride2_nrf"))
        let killAt = (inputs.first?.t ?? 0) + 900
        let db = try AppDatabase.openTemporary(build: "test")
        defer { db.discardTemporary() }
        let stateURL = Recorder.stateURL(for: db)
        let first = recorder(db, stateURL: stateURL)
        await first.process(inputs.filter { $0.t < killAt })
        let second = recorder(nil, stateURL: stateURL)
        await second.attach(db, now: killAt + 600)
        let ids = await second.closedRideIds
        XCTAssertEqual(ids.count, 1)
        let q = RideQueries(db)
        let ride = try XCTUnwrap(try q.ride(id: try XCTUnwrap(ids.first)))
        XCTAssertEqual(ride.status, "recovered")
        XCTAssertEqual(ride.endReason, "recovered")
        let endAt = try XCTUnwrap(ride.endAt)
        XCTAssertLessThanOrEqual(Double(endAt) / 1000, killAt + epochOffset + 0.001)
        XCTAssertGreaterThan(ride.energyWhRaw ?? 0, 50, "totals from the samples stored before the kill")
        XCTAssertTrue(try q.openRides().isEmpty)
    }
}
