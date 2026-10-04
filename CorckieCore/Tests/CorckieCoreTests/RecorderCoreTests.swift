import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-09: the Recorder's pure part on the fake scooter, applied to an in-memory store the way the app's Recorder
/// applies it to the database: golden rides 1 and 2 give 437 Wh / 16.3 km and 322 Wh / 13.7 km from the stored
/// samples; raw chunks, snapshots, live input once a second, held top speed; kill mid-ride → resume (SC-14).
final class RecorderCoreTests: XCTestCase {
    /// What the database would hold.
    final class MemoryStore {
        var started: [Int: Double] = [:]
        var cancelled: [Int] = []
        var samples: [Int: [RecorderSample]] = [:]
        var chunks: [Int: [(startT: Double, endT: Double, blob: Data)]] = [:]
        var gapsOpened: [Int: [Double]] = [:]
        var gapsClosed: [Int: [Double]] = [:]
        var progress: [Int: RecorderProgress] = [:]
        var closes: [RecorderClose] = []
        var snapshots: [RecorderSnapshot] = []
        var lives: [LiveState] = []
        var active: [Bool] = []

        func apply(_ a: RecorderAction) {
            switch a {
            case let .rideStarted(seq, startT, _): started[seq] = startT
            case let .rideCancelled(seq):
                cancelled.append(seq)
                samples[seq] = nil
            case let .samples(seq, list): samples[seq, default: []] += list
            case let .rawChunk(seq, s, e, blob): chunks[seq, default: []].append((startT: s, endT: e, blob: blob))
            case let .gapOpened(seq, s, _): gapsOpened[seq, default: []].append(s)
            case let .gapClosed(seq, e): gapsClosed[seq, default: []].append(e)
            case let .progress(p): progress[p.seq] = p
            case let .rideEnded(c): closes.append(c)
            case let .snapshot(s): snapshots.append(s)
            case let .live(_, state): lives.append(state)
            case let .rideActive(on): active.append(on)
            case .rideConfirmed, .sameRideOffered, .rideMerged, .batteryRanOut: break
            }
        }

        func metrics(_ c: RecorderClose) -> RideMetrics {
            c.end.metrics((samples[c.end.ride.seq] ?? []).map(\.sample), ignoredReadings: c.ignoredReadings)
        }
    }

    private func fixture(_ id: String, _ file: String, faults: (Double) -> [Fault] = { _ in [] }) throws -> SimStream {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == id })
        let events = try sim.events(from: Fixtures.text(file))
        let start = events.first?.t ?? 0
        return SimStream(scooter: FaultInjector.apply(faults(start), to: events), phone: [])
    }

    func test_golden_rides1and2_throughTheRecorder_fromTheStoredSamples() throws {
        for (id, file, wh, km) in [("F2", "F2_ride1_nrf.csv", 437.0, 16.3), ("F5", "F5_ride2_nrf.csv", 322.0, 13.7)] {
            let store = MemoryStore()
            var core = RideRecorderCore()
            RecorderRunner.play(RecorderRunner.inputs(try fixture(id, file)), core: &core, apply: store.apply)
            XCTAssertEqual(store.closes.count, 1, id)
            let close = try XCTUnwrap(store.closes.first)
            let m = store.metrics(close)
            XCTAssertEqual(m.energyWhRaw, wh, accuracy: wh * 0.03, id)
            XCTAssertEqual(m.distanceKm, km, accuracy: 0.15, id)
            XCTAssertEqual(close.end.reason, .scooterOff, id)
            XCTAssertGreaterThanOrEqual(close.topSpeedKmh, m.topSpeedKmh - 0.01, "\(id): held top ≥ the 5-s samples' top")
            XCTAssertFalse(store.chunks[close.end.ride.seq]?.isEmpty ?? true, "\(id): raw chunks stored")
            XCTAssertGreaterThan(store.snapshots.count, 10, id)
            XCTAssertEqual(store.active.first, true, id)
            XCTAssertEqual(store.active.last, false, id)
            XCTAssertNil(store.snapshots.last?.engine.ride, "\(id): the last snapshot has no open ride")
            // samples are 5 s apart and arrive in 30-s batches
            let s = store.samples[close.end.ride.seq] ?? []
            XCTAssertGreaterThan(s.count, 100, id)
            XCTAssertGreaterThan(s.filter { $0.mode == "scooter" }.count, s.count / 2, id)
        }
    }

    func test_ride1_heldTopSpeed_isTheRealPeak() throws {
        let store = MemoryStore()
        var core = RideRecorderCore()
        RecorderRunner.play(RecorderRunner.inputs(try fixture("F2", "F2_ride1_nrf.csv")), core: &core, apply: store.apply)
        let close = try XCTUnwrap(store.closes.first)
        XCTAssertEqual(close.topSpeedKmh, 50.7, accuracy: 1.0, "every checked frame, not only the samples")
    }

    func test_liveInputOnceASecond_andRawChunksHoldThePackets() throws {
        let stream = try fixture("F5", "F5_ride2_nrf.csv")
        let inputs = RecorderRunner.inputs(stream, tailS: 10)
        let ticks = inputs.filter { $0.input == .tick }.count
        let store = MemoryStore()
        var core = RideRecorderCore()
        RecorderRunner.play(inputs, core: &core, apply: store.apply)
        XCTAssertEqual(store.lives.count, ticks, "one live update per tick (1 s)")
        let close = try XCTUnwrap(store.closes.first)
        let packets = (store.chunks[close.end.ride.seq] ?? []).flatMap { RecorderRaw.unpack($0.blob, startT: $0.startT) }
        XCTAssertGreaterThan(packets.count, 1_000)
        XCTAssertTrue(packets.allSatisfy { $0.bytes.count > 0 })
    }

    func test_rawPack_roundTrip() {
        let p: [(t: Double, bytes: [UInt8])] = [(t: 10, bytes: [1, 2, 3]), (t: 10.25, bytes: Array(repeating: 7, count: 20))]
        let back = RecorderRaw.unpack(RecorderRaw.pack(p, startT: 10), startT: 10)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].t, 10.25, accuracy: 0.001)
        XCTAssertEqual(back[1].bytes, p[1].bytes)
    }

    func test_SC14_killMidRide_snapshotResumes_totalsStillGolden() throws {
        let inputs = RecorderRunner.inputs(try fixture("F5", "F5_ride2_nrf.csv"))
        let killAt = (inputs.first?.t ?? 0) + 900
        let store = MemoryStore()
        var core = RideRecorderCore()
        RecorderRunner.play(inputs.filter { $0.t < killAt }, core: &core, apply: store.apply)
        // the app is killed: only what was flushed survives (samples every 30 s, snapshot every 5 s)
        let snap = try XCTUnwrap(store.snapshots.last)
        let json = try JSONEncoder().encode(snap)
        let restoredSnap = try JSONDecoder().decode(RecorderSnapshot.self, from: json)
        let back = killAt + 3
        let seq = try XCTUnwrap(restoredSnap.seq)
        let lastStored = (store.samples[seq] ?? []).map(\.sample.t).max().map { $0 + (restoredSnap.startT ?? 0) }
        let restored = RideRecorderCore.restore(restoredSnap, lastDataT: lastStored, now: back)
        var resumed = restored.core
        let decision = restored.decision
        XCTAssertEqual(decision, .resume)
        RecorderRunner.play(inputs.filter { $0.t >= back }, core: &resumed, apply: store.apply)
        XCTAssertEqual(store.started.count, 1, "the same ride goes on")
        let close = try XCTUnwrap(store.closes.first)
        XCTAssertEqual(close.end.ride.seq, seq)
        let m = store.metrics(close)
        XCTAssertEqual(m.energyWhRaw, 322, accuracy: 322 * 0.05, "≤ 30 s of samples lost")
        XCTAssertEqual(m.distanceKm, 13.7, accuracy: 0.15, "the odometer fills the lost seconds")
    }

    func test_killLong_isRecovered_orDiscardedWhenNeverConfirmed() throws {
        let inputs = RecorderRunner.inputs(try fixture("F5", "F5_ride2_nrf.csv"))
        let killAt = (inputs.first?.t ?? 0) + 600
        let store = MemoryStore()
        var core = RideRecorderCore()
        RecorderRunner.play(inputs.filter { $0.t < killAt }, core: &core, apply: store.apply)
        let snap = try XCTUnwrap(store.snapshots.last)
        let (_, decision) = RideRecorderCore.restore(snap, lastDataT: nil, now: killAt + 600)
        guard case let .endRecovered(end) = decision else { return XCTFail("expected recovered, got \(decision)") }
        XCTAssertEqual(end.status, "recovered")
        XCTAssertLessThanOrEqual(end.endT, killAt)
        XCTAssertLessThanOrEqual(killAt - snap.engine.now, RideRecorderCore.snapshotIntervalS + 0.5, "≤ 5 s lost")
    }

    func test_phoneMode_GPSOnlySamples_markedPhone_gapActions() throws {
        let s = try XCTUnwrap(SyntheticScenario.all.first { $0.id == "SPD-46-GPS" }).build()
        let store = MemoryStore()
        var core = RideRecorderCore()
        RecorderRunner.play(RecorderRunner.inputs(s, tailS: 5), core: &core, apply: store.apply)
        let seq = try XCTUnwrap(store.started.keys.first)
        XCTAssertEqual(store.gapsOpened[seq]?.count, 1)
        XCTAssertEqual(store.gapsClosed[seq]?.count, 1)
        // still riding at the end of the stream: flush what is pending
        for a in core.flushNow(at: 140) { store.apply(a) }
        let phone = (store.samples[seq] ?? []).filter { $0.mode == "phone" }
        XCTAssertFalse(phone.isEmpty)
        XCTAssertTrue(phone.allSatisfy { $0.sample.speedKmh == nil && $0.sample.lat != nil })
        XCTAssertTrue(store.lives.contains { $0.slow && $0.speedLabel == "GPS" }, "SLOW on GPS speed reaches the live view")
    }
}
