import CorckieCore
import CorckieSim
import Foundation
import Observation

/// The in-app fake scooter (TESTING §5): a bundled anonymised fixture replayed through the
/// same pipeline as the real link, at 1×–50×, with an optional fault scenario.
/// Safety: refuses to start while the real scooter is connected and stops if it connects;
/// a "SIMULATED" banner shows on every screen while it runs. Simulated data is never
/// written to the real database (the foundation build has no recorder yet; P5 gives the
/// simulator its own temporary database).
@Observable
final class SimulatorRunner {
    private(set) var running = false
    private(set) var pipeline = ScooterPipeline()
    private(set) var progress = 0.0
    private(set) var message: String?
    private(set) var finishedFixture: String?

    var fixtureID = "F2"
    var scenarioID = SimScenario.clean.id
    var speed: Double = 50

    @ObservationIgnored private var session: ReplaySession?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()

    func start(realScooterConnected: Bool) {
        guard !realScooterConnected else {
            message = "The real scooter is connected · the simulator can't run during a real ride"
            return
        }
        guard let fixture = SimFixture.all.first(where: { $0.id == fixtureID }),
              let url = Bundle.main.url(forResource: fixture.fileName, withExtension: "csv", subdirectory: "Fixtures") else {
            message = "Fixture not found in the app"
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var events = try fixture.events(from: text)
            let scenario = SimScenario.all.first { $0.id == scenarioID } ?? .clean
            events = FaultInjector.apply(scenario.faults(events.first?.t ?? 0), to: events)
            session = ReplaySession(events: events, speed: speed)
            pipeline = ScooterPipeline()
            progress = 0
            message = nil
            finishedFixture = nil
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
        if let reason { message = reason }
    }

    private func tick() {
        guard let session else { return }
        let now = Date()
        let due = session.advance(realSeconds: now.timeIntervalSince(lastTick))
        lastTick = now
        pipeline.handle(Array(due))
        progress = session.progress
        if session.isFinished {
            finish()
        }
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
    }
}
