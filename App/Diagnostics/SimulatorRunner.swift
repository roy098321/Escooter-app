import CorckieCore
import CorckieSim
import Foundation
import GRDB
import Observation

/// The in-app fake scooter (TESTING §5): a bundled anonymised fixture replayed through the
/// same pipeline as the real link, at 1×–50×, with an optional fault scenario.
/// Safety: refuses to start while the real scooter is connected and stops if it connects;
/// a "SIMULATED" banner shows on every screen while it runs. Simulated data is never
/// written to the real database (d8 checks the real ride count is unchanged).
///
/// Phone takeover (G1, d7): while the simulated scooter is disconnected, the live speed is the
/// ride's recorded GPS speed, labelled "GPS"; the totals keep counting scooter data only.
@Observable
final class SimulatorRunner {
    private(set) var running = false
    private(set) var pipeline = ScooterPipeline()
    private(set) var progress = 0.0
    private(set) var message: String?
    private(set) var finishedFixture: String?
    /// G1 phone mode: GPS speed while the scooter is gone (nil = scooter connected)
    private(set) var gpsSpeedKmh: Double?
    private(set) var phoneModeSeconds = 0.0

    var fixtureID = "F2"
    var scenarioID = SimScenario.clean.id
    var speed: Double = 50

    @ObservationIgnored private var session: ReplaySession?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var gpsTrack: [MergedSample] = []
    @ObservationIgnored private var realRidesBefore: Int?
    @ObservationIgnored private var lastVirtual = 0.0

    func start(realScooterConnected: Bool) {
        guard !realScooterConnected else {
            message = "The real scooter is connected · the simulator can't run during a real ride"
            return
        }
        if scenarioID == "D7" { fixtureID = "F3" }        // d7 needs the ride with GPS
        guard let fixture = SimFixture.all.first(where: { $0.id == fixtureID }),
              let url = Bundle.main.url(forResource: fixture.fileName, withExtension: "csv", subdirectory: "Fixtures") else {
            message = "Fixture not found in the app"
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var events = try fixture.events(from: text)
            gpsTrack = fixture.kind == .samples ? (try LogReader.mergedSamples(text)) : []
            let scenario = SimScenario.all.first { $0.id == scenarioID } ?? .clean
            events = FaultInjector.apply(scenario.faults(events.first?.t ?? 0), to: events)
            session = ReplaySession(events: events, speed: speed)
            pipeline = ScooterPipeline()
            progress = 0
            message = nil
            finishedFixture = nil
            gpsSpeedKmh = nil
            phoneModeSeconds = 0
            lastVirtual = events.first?.t ?? 0
            realRidesBefore = Self.realRideCount()
            running = true
            lastTick = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            Log.info(source: "simulator", "Started \(fixture.id) at \(Int(speed))× with \(scenario.id)")
        } catch {
            message = "Couldn't read the fixture: \(error.localizedDescription)"
            Log.error(source: "simulator", message ?? "")
        }
    }

    func stop(reason: String? = nil) {
        timer?.invalidate()
        timer = nil
        running = false
        gpsSpeedKmh = nil
        if let reason { message = reason }
        checkRealDataApart()
    }

    private func tick() {
        guard let session else { return }
        let now = Date()
        let due = session.advance(realSeconds: now.timeIntervalSince(lastTick))
        lastTick = now
        pipeline.handle(Array(due))
        progress = session.progress
        let virtual = session.clock.now
        // G1 phone takeover after the first connection: GPS speed while the scooter is gone
        if !pipeline.connected, pipeline.connects > 0, !session.isFinished {
            gpsSpeedKmh = gpsSpeed(at: virtual)
            phoneModeSeconds += max(0, virtual - lastVirtual)
        } else {
            gpsSpeedKmh = nil
        }
        lastVirtual = virtual
        if session.isFinished {
            finish()
        }
    }

    private func gpsSpeed(at t: Double) -> Double? {
        guard !gpsTrack.isEmpty else { return nil }
        let index = min(gpsTrack.count - 1, max(0, Int(t)))
        return gpsTrack[index].gpsSpeedKmh
    }

    private func finish() {
        stop()
        finishedFixture = fixtureID
        let t = pipeline.totals
        let summary = String(format: "%@ at %.0f×: %.0f Wh, %.1f km, top %.0f km/h, %ld readings ignored",
                             fixtureID, speed, t.energyWhRaw, t.distanceKm, t.topSpeedKmh, pipeline.plausibility.ignoredReadings)
        message = "Finished · " + summary
        Log.info(source: "simulator", summary)
        if fixtureID == "F2", speed >= 50, scenarioID == SimScenario.clean.id {
            let ok = abs(t.energyWhRaw - 437) <= 437 * 0.03 && abs(t.distanceKm - 16.3) <= 0.05
            CheckResults.shared.set("d1", ok ? .pass : .fail, summary)
        }
        if scenarioID == "D7" {
            // Scooter-only totals: distance from the odometer (13.7 km), no energy invented for the gap
            let tookOver = phoneModeSeconds >= 50
            let scooterOnly = abs(t.distanceKm - 13.7) <= 0.05 && t.energyWhRaw < 322
            let note = String(format: "Phone took over for %.0f s (GPS speed shown, labelled); totals scooter-only: %.0f Wh, %.1f km",
                              phoneModeSeconds, t.energyWhRaw, t.distanceKm)
            CheckResults.shared.set("d7", tookOver && scooterOnly ? .pass : .fail, note)
        }
    }

    /// d8: a simulator run never changes the real database.
    private func checkRealDataApart() {
        guard let before = realRidesBefore else { return }
        realRidesBefore = nil
        guard let after = Self.realRideCount() else { return }
        CheckResults.shared.set("d8", after == before ? .pass : .fail,
                                "Real rides before \(before), after \(after) (simulated data kept apart)")
    }

    private static func realRideCount() -> Int? {
        guard let db = AppModel.shared.database else { return nil }
        return try? db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") ?? 0 }
    }
}
