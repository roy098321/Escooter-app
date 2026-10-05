import CorckieCore
import Foundation

// M1-09: the Recorder (ARCHITECTURE §2.2, §5). ONE actor between the sources and the store: scooter packets,
// phone GPS and barometer, the buttons and a 1-s tick go in (in order); `RideRecorderCore` (CorckieCore, Linux tested)
// runs the ride engine and says what to store; this actor writes it through `RideQueries` (rides, samples, raw
// chunks, gaps, stops), saves the engine state for recovery, and hands the live input and the notifier
// events to the app through `RecorderHooks`. The same actor records into a temporary database for the simulator
// and the app-tests. It never talks to the scooter (read-only link).
// This file is compiled into AppTests too (with App/Store), so it uses nothing else from the app.

/// What the Recorder tells the rest of the app. Called on the Recorder's own executor: hop to the main thread
/// in the closure. The tests leave them empty.
struct RecorderHooks: Sendable {
    /// Stage 1 reached: `Notifier.shared.rideStarted()`
    var rideStarted: @Sendable () -> Void = {}
    /// `Notifier.shared.rideActive`
    var rideActive: @Sendable (Bool) -> Void = { _ in }
    /// Location on at stage 1, off when the ride closes (ARCHITECTURE §5.1)
    var location: @Sendable (Bool) -> Void = { _ in }
    /// About once a second: what the live view shows
    var live: @Sendable (LiveInput, LiveState) -> Void = { _, _ in }
    /// A ride row was closed (id, ended / recovered)
    var rideClosed: @Sendable (String, String) -> Void = { _, _ in }
    var log: @Sendable (String) -> Void = { _ in }

    static let none = RecorderHooks()
}

actor Recorder {
    /// The file next to the database that holds the saved state (engine JSON + row ids), every 5 s while recording.
    struct SavedState: Codable {
        var core: RecorderSnapshot
        var rideIds: [Int: String]
        var rideStartT: [Int: Double]
        var gapRowIds: [Int: Int64]
        var chunkSeq: [Int: Int]
    }

    private var core = RideRecorderCore()
    private var rideIds: [Int: String] = [:]
    private var rideStartT: [Int: Double] = [:]
    private var gapRowIds: [Int: Int64] = [:]
    private var chunkSeq: [Int: Int] = [:]
    private var database: AppDatabase?
    /// Store actions that arrived before the database could be opened (iOS relaunch before the first unlock)
    private var waiting: [RecorderAction] = []
    private let simulated: Bool
    private let build: String
    private let hooks: RecorderHooks
    private var stateURL: URL?
    /// Added to the input clock to get epoch seconds (0 for the real app, which feeds epoch seconds)
    private let epochOffset: Double

    /// Rides closed so far (row ids, newest last)
    private(set) var closedRideIds: [String] = []
    private(set) var writeErrors: [String] = []
    private(set) var lastLive: LiveState?

    init(database: AppDatabase?, simulated: Bool, build: String, stateURL: URL?, epochOffset: Double = 0,
         hooks: RecorderHooks = .none) {
        self.database = database
        self.simulated = simulated
        self.build = build
        self.stateURL = stateURL
        self.epochOffset = epochOffset
        self.hooks = hooks
    }

    /// The state file for a database: next to it (a temporary database keeps its own).
    static func stateURL(for database: AppDatabase) -> URL {
        database.url.deletingLastPathComponent().appendingPathComponent("recorder-state.json")
    }

    var rideActive: Bool { core.engine.rideActive }

    func setStateURL(_ url: URL?) { stateURL = url }
    var engine: RideEngine { core.engine }

    // MARK: Input

    func process(_ input: RecorderInput, at t: Double) {
        for a in core.handle(input, at: t) { apply(a) }
    }

    func process(_ inputs: [(t: Double, input: RecorderInput)]) {
        for i in inputs { process(i.input, at: i.t) }
    }

    /// Writes what is pending (going to the background, or the end of a simulator run).
    func flush(at t: Double) {
        for a in core.flushNow(at: t) { apply(a) }
    }

    // MARK: Database and recovery

    /// The database became readable: write what waited, then recover a ride left open by a crash or a kill.
    func attach(_ db: AppDatabase, now: Double) {
        database = db
        let queued = waiting
        waiting = []
        for a in queued { store(a) }
        recover(now: now)
    }

    /// CALC_SPEC M2 "Recovery" (SC-14): resume a young ride from the saved state, close an old one as recovered at
    /// its last sample, delete one that was never confirmed; any other ride still `recording` is closed too.
    func recover(now: Double) {
        guard let db = database else { return }
        let q = RideQueries(db)
        if let url = stateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data), core.engine.ride == nil {
            rideIds = saved.rideIds
            rideStartT = saved.rideStartT
            gapRowIds = saved.gapRowIds
            chunkSeq = saved.chunkSeq
            var lastDataT: Double?
            if let seq = saved.core.seq, let id = rideIds[seq], let start = rideStartT[seq],
               let ms = try? q.lastSampleT(rideId: id) {
                lastDataT = start + Double(ms) / 1000
            }
            let restored = RideRecorderCore.restore(saved.core, lastDataT: lastDataT, now: now)
            core = restored.core
            switch restored.decision {
            case .nothingOpen, .resume:
                break
            case .endRecovered(let end):
                close(RecorderClose(end: end, topSpeedKmh: saved.core.topSpeedKmh, ignoredReadings: 0))
                hooks.log("Recovered ride \(rideIds[end.ride.seq] ?? "?") at its last sample")
            case let .discard(seq, _):
                if let id = rideIds[seq] { _ = try? q.delete(rideId: id) }
                rideIds[seq] = nil
                hooks.log("Discarded an unconfirmed ride left open")
            }
            if restored.decision == .resume { hooks.log("Resumed the open ride after a relaunch") }
        }
        // Rows still `recording` that the saved state does not own: close them at their last sample
        let owned = core.engine.ride.flatMap { rideIds[$0.seq] }
        for ride in (try? q.openRides()) ?? [] where ride.id != owned && ride.isSimulated == simulated {
            closeOrphan(ride, q)
        }
        saveState()
    }

    private func closeOrphan(_ ride: RideRecord, _ q: RideQueries) {
        do {
            let samples = try q.samples(rideId: ride.id)
            guard let last = samples.last else {
                try q.delete(rideId: ride.id)
                return
            }
            var r = ride
            let m = RideMetricsCalculator.compute(samples.map(Self.sample(from:)))
            Self.fill(&r, m, topSpeedKmh: m.topSpeedKmh)
            r.status = "recovered"
            r.endReason = RideEndReason.recovered.rawValue
            r.endAt = ride.startAt + last.t
            r.kind = RideSizeClass.of(distanceM: m.distanceM).rawValue
            try q.save(r)
            do { try RouteProcessor.process(rideId: r.id, database: q.database) } catch { note("routes \(r.id): \(error.localizedDescription)") }
            hooks.rideClosed(r.id, r.status)
        } catch {
            note("orphan ride \(ride.id): \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    private func apply(_ a: RecorderAction) {
        switch a {
        case .rideStarted:
            hooks.rideStarted()
            hooks.location(true)
        case .rideCancelled:
            hooks.location(false)
        case let .live(input, state):
            lastLive = state
            hooks.live(input, state)
            return
        case let .rideActive(on):
            hooks.rideActive(on)
            return
        case let .rideConfirmed(seq, _, by):
            hooks.log("Ride \(seq) confirmed by \(by.rawValue)")
        case let .sameRideOffered(seq, previous):
            hooks.log("Same ride? offered for \(seq) (after \(previous))")
        default:
            break
        }
        if case .snapshot(let s) = a {
            saveState(s)
            return
        }
        if database == nil {
            waiting.append(a)
            if waiting.count > 50_000 { waiting.removeFirst(10_000) }
            return
        }
        store(a)
    }

    private func store(_ a: RecorderAction) {
        guard let db = database else { return }
        let q = RideQueries(db)
        do {
            switch a {
            case let .rideStarted(seq, startT, _):
                let id = UUID().uuidString
                rideIds[seq] = id
                rideStartT[seq] = startT
                var r = RideRecord(id: id, startAt: ms(startT))
                r.isSimulated = simulated
                r.createdBuild = build
                r.utcOffsetMin = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: startT + epochOffset)) / 60
                try q.save(r)
                trimIds()
            case let .rideCancelled(seq):
                if let id = rideIds[seq] { try q.delete(rideId: id) }
                rideIds[seq] = nil
                gapRowIds[seq] = nil
            case let .samples(seq, list):
                guard let id = rideIds[seq] else { return }
                try q.insert(samples: list.map { Self.record(id, $0) })
            case let .rawChunk(seq, startT, endT, blob):
                guard let id = rideIds[seq] else { return }
                let n = chunkSeq[seq, default: 0]
                chunkSeq[seq] = n + 1
                let packed = try? (blob as NSData).compressed(using: .zlib) as Data
                try q.insert(chunk: RawChunkRecord(rideId: id, seq: n, startAt: ms(startT), endAt: ms(endT), kind: "scooter",
                                                   codec: packed != nil ? "zlib-v1" : "raw-v1", blob: packed ?? blob))
            case let .gapOpened(seq, startT, reason):
                guard let id = rideIds[seq] else { return }
                let gap = try q.openGap(rideId: id, kind: "scooter", startT: rel(seq, startT))
                gapRowIds[seq] = gap.id
                hooks.log("Phone took over (\(reason.rawValue))")
            case let .gapClosed(seq, endT):
                if let gid = gapRowIds[seq] { try q.closeGap(id: gid, endT: rel(seq, endT)) }
                gapRowIds[seq] = nil
            case let .progress(p):
                guard let id = rideIds[p.seq], var r = try q.ride(id: id) else { return }
                r.odoStartKm = p.odoStartKm
                r.odoEndKm = p.odoLastKm
                r.distanceM = p.distanceM
                r.topSpeedMps = p.topSpeedKmh / 3.6
                r.firstMoveAt = p.firstMoveT.map { ms($0) }
                r.lastMoveAt = p.lastMoveT.map { ms($0) }
                try q.save(r)
            case let .rideMerged(seq, intoSeq):
                guard let id = rideIds[seq], let intoId = rideIds[intoSeq] else { return }
                let group = try q.ride(id: intoId)?.mergeGroupId ?? intoId
                if var into = try q.ride(id: intoId), into.mergeGroupId == nil {
                    into.mergeGroupId = group
                    try q.save(into)
                }
                if var r = try q.ride(id: id) {
                    r.mergeGroupId = group
                    try q.save(r)
                }
            case let .batteryRanOut(seq, pct):
                // D3 / T80: the real empty point for range (no schema change: a setting row)
                let id = rideIds[seq] ?? "?"
                try q.setSetting(key: "t80.batteryRanOut", json: "{\"pct\":\(pct),\"rideId\":\"\(id)\"}")
            case let .rideEnded(c):
                close(c)
            case .rideConfirmed, .sameRideOffered, .live, .rideActive, .snapshot:
                break
            }
        } catch {
            note("\(a.kindName): \(error.localizedDescription)")
        }
    }

    /// Closes the ride row from the engine's end and the stored samples (the totals are the stored ones, M1-06).
    private func close(_ c: RecorderClose) {
        let end = c.end
        let seq = end.ride.seq
        defer {
            gapRowIds[seq] = nil
            hooks.location(false)
        }
        guard let db = database, let id = rideIds[seq] else { return }
        let q = RideQueries(db)
        do {
            guard var r = try q.ride(id: id) else { return }
            let samples = try q.samples(rideId: id).map(Self.sample(from:))
            let m = end.metrics(samples, ignoredReadings: c.ignoredReadings)
            Self.fill(&r, m, topSpeedKmh: c.topSpeedKmh)
            if m.distanceM <= 0 { r.distanceM = end.distanceM }
            r.status = end.status
            r.kind = end.sizeClass.rawValue
            r.endAt = ms(end.endT)
            r.endReason = end.reason.rawValue
            r.firstMoveAt = end.ride.firstMoveT.map { ms($0) }
            r.lastMoveAt = end.ride.lastMoveT.map { ms($0) }
            if let into = end.ride.mergedIntoSeq, let intoId = rideIds[into] {
                r.mergeGroupId = try q.ride(id: intoId)?.mergeGroupId ?? intoId
            }
            try q.save(r)
            let start = end.ride.startT
            func relMs(_ t: Double) -> Int64 { Int64(((t - start) * 1000).rounded()) }
            try q.replaceStops(rideId: id, stops: end.ride.stops.map {
                StopRecord(rideId: id, startT: relMs($0.startT), endT: $0.endT.map(relMs), lat: $0.lat, lon: $0.lon)
            })
            try q.replaceGaps(rideId: id, kind: "scooter", gaps: end.ride.gapList.map { (startT: relMs($0.startT), endT: $0.endT.map(relMs)) })
            for w in end.ride.walks {
                try q.setSampleMode(rideId: id, fromT: relMs(w.startT), toT: relMs(w.endT ?? end.endT), mode: "walk")
            }
            // M3-01: battery calibration from the stored rides; re-runs the rides' used % (a failure never stops the close)
            do { try CalibrationUpdater.update(db, nowMs: ms(end.endT)) } catch { note("calibration \(id): \(error.localizedDescription)") }
            // M2: where does this ride belong? (places, routes, variants); a failure here never stops the close
            do { try RouteProcessor.process(rideId: id, database: db) } catch { note("routes \(id): \(error.localizedDescription)") }
            closedRideIds.append(id)
            hooks.rideClosed(id, r.status)
            updateUsualPctPerKm(q)
        } catch {
            note("close \(id): \(error.localizedDescription)")
        }
    }

    /// Decision 5: usual %/km = median of the last 10 rides that have one (for "~N% est." in phone mode).
    private func updateUsualPctPerKm(_ q: RideQueries) {
        let rides = ((try? q.rides(limit: 30)) ?? []).filter { $0.isSimulated == simulated && $0.kind == "ride" }
        let values = rides.compactMap { r -> Double? in
            guard let used = r.usedPct, let d = r.distanceM, d >= 1_000 else { return nil }
            return used / (d / 1000)
        }.prefix(10).sorted()
        guard !values.isEmpty else {
            // M3-01: no ride with a used % yet: the usual Wh/km over the calibration (prior or learned) instead of the fixed 3%/km
            guard let db = database else { return }
            let whPerKm = rides.compactMap { r -> Double? in
                guard let e = r.energyWhRaw, e > 0, let d = r.distanceM, d >= 1_000, (r.gapScooterS ?? 0) <= T.t41CalibrationMaxGapS else { return nil }
                return e / (d / 1000)
            }.prefix(10).sorted()
            guard !whPerKm.isEmpty else { return }
            let m = whPerKm.count % 2 == 1 ? whPerKm[whPerKm.count / 2] : (whPerKm[whPerKm.count / 2 - 1] + whPerKm[whPerKm.count / 2]) / 2
            core.setUsualPctPerKm(CalibrationUpdater.current(db).pctPerKm(whPerKm: m))
            return
        }
        let n = values.count
        let median = n % 2 == 1 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) / 2
        core.setUsualPctPerKm(median)
    }

    // MARK: State file

    private func saveState(_ snap: RecorderSnapshot? = nil) {
        guard let url = stateURL else { return }
        let state = SavedState(core: snap ?? core.snapshot(), rideIds: rideIds, rideStartT: rideStartT, gapRowIds: gapRowIds,
                               chunkSeq: chunkSeq)
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            note("state file: \(error.localizedDescription)")
        }
    }

    /// Keeps the id maps small: the open ride and the last few closed ones (Same ride? can still join them).
    private func trimIds() {
        guard rideIds.count > 4 else { return }
        for key in rideIds.keys.sorted().dropLast(4) {
            rideIds[key] = nil
            rideStartT[key] = nil
            chunkSeq[key] = nil
        }
    }

    private func note(_ text: String) {
        writeErrors.append(text)
        if writeErrors.count > 50 { writeErrors.removeFirst() }
        hooks.log("Recorder: " + text)
    }

    // MARK: Conversions

    private func ms(_ t: Double) -> Int64 { Int64(((t + epochOffset) * 1000).rounded()) }

    private func rel(_ seq: Int, _ t: Double) -> Int64 {
        Int64(((t - (rideStartT[seq] ?? t)) * 1000).rounded())
    }

    static func record(_ rideId: String, _ x: RecorderSample) -> RideSampleRecord {
        let s = x.sample
        var r = RideSampleRecord(rideId: rideId, t: Int64((s.t * 1000).rounded()))
        r.speedMps = s.speedKmh.map { $0 / 3.6 }
        r.gpsSpeedMps = s.gpsSpeedKmh.map { $0 / 3.6 }
        r.lat = s.lat
        r.lon = s.lon
        r.hAccM = s.hAccM
        r.altBaroM = s.altBaroM
        r.voltage = s.voltage
        r.currentA = s.currentA
        r.powerW = s.powerW
        r.batteryPct = s.batteryPct
        r.tempC = s.tempC
        r.odometerKm = s.odometerKm
        r.mode = x.mode
        r.moving = s.moving
        return r
    }

    static func sample(from r: RideSampleRecord) -> RideSample {
        RideSample(t: Double(r.t) / 1000, speedKmh: r.speedMps.map { $0 * 3.6 }, gpsSpeedKmh: r.gpsSpeedMps.map { $0 * 3.6 },
                   lat: r.lat, lon: r.lon, hAccM: r.hAccM, altBaroM: r.altBaroM, voltage: r.voltage, currentA: r.currentA,
                   batteryPct: r.batteryPct, tempC: r.tempC, odometerKm: r.odometerKm)
    }

    static func fill(_ r: inout RideRecord, _ m: RideMetrics, topSpeedKmh: Double) {
        r.distanceM = m.distanceM
        r.totalS = m.totalS
        r.movingS = m.movingS
        r.avgMovingMps = m.avgMovingMps
        r.topSpeedMps = max(m.topSpeedKmh, topSpeedKmh) / 3.6
        r.stops = m.stops
        r.energyWhRaw = m.energyWhRaw
        r.energyWhCal = nil
        r.usedPct = m.usedPct
        r.usedPctMethod = m.usedPctMethod
        r.startRestPct = m.startRestPct
        r.endRestPct = m.endRestPct
        r.odoStartKm = m.odoStartKm
        r.odoEndKm = m.odoEndKm
        r.elevGainM = m.elevGainM
        r.elevLossM = m.elevLossM
        r.elevProvisional = m.elevProvisional
        r.tempStartC = m.tempStartC
        r.tempPeakC = m.tempPeakC
        r.tempRiseC = m.tempRiseC
        r.gapScooterS = m.gapScooterS
        r.hasGps = m.hasGps
        r.ignoredReadings = m.ignoredReadings
    }
}

extension RecorderAction {
    /// For the error log
    var kindName: String {
        switch self {
        case .rideStarted: return "ride start"
        case .rideConfirmed: return "confirm"
        case .rideCancelled: return "cancel"
        case .samples: return "samples"
        case .rawChunk: return "raw chunk"
        case .gapOpened: return "gap open"
        case .gapClosed: return "gap close"
        case .progress: return "ride row"
        case .sameRideOffered: return "same ride"
        case .rideMerged: return "merge"
        case .batteryRanOut: return "battery ran out"
        case .rideEnded: return "ride end"
        case .snapshot: return "state"
        case .live: return "live"
        case .rideActive: return "ride active"
        }
    }
}
