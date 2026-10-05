import CorckieSim
import Foundation
import Observation

/// "Run all automatic" (M1-00): every check the phone can do by itself, in one go, then a
/// summary. Scooter, ride and owner-judged checks are left for the To do list.
@MainActor
@Observable
final class AutoRunner {
    static let shared = AutoRunner()

    private(set) var running = false
    private(set) var step = ""
    /// M1-00b: which of the `stepCount` jobs is running, for the progress bar
    private(set) var stepIndex = 0
    static let stepCount = 8
    private(set) var summary: [String] = []

    /// The checks this button can settle
    static let ids = ["h1", "a3", "a6", "u2", "u3", "u4", "u5", "u6", "u7", "u8", "u9", "u10", "u11", "u12", "u13", "u14", "u15", "u16", "u17", "u18", "u19", "u20", "u21", "u22", "u23", "u24", "u25", "u26", "u27", "u28", "o1", "e1", "d6", "d9", "d1", "d7", "d8",
                      "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7"]

    func run() async {
        guard !running else { return }
        running = true
        summary = []
        let results = CheckResults.shared
        let model = AppModel.shared

        step = "Permissions"
        stepIndex = 1
        PermissionsCheck.shared.refresh()
        try? await Task.sleep(nanoseconds: 800_000_000)

        step = "App ID, database, fuel price setting"
        stepIndex = 2
        InstallChecks.run(database: model.database, error: model.databaseError)

        step = "Error log"
        stepIndex = 3
        let marker = "Automatic test entry \(UUID().uuidString.prefix(8))"
        Log.info(source: "developer", marker)
        let stored = model.database != nil && ErrorLog.shared.lines().contains { $0.hasSuffix(marker) }
        results.set("d6", stored ? .pass : .fail, stored ? "Stored in the database and read back" : "Not found in the database log")

        step = "Backup + restore"
        stepIndex = 4
        BackupRestoreTest.run()

        step = "Phone replay, ride storage, ride numbers, live rules"
        stepIndex = 5
        PhoneReplayCheck.run()
        RideStorageCheck.run(real: model.database)
        RideMetricsCheck.run()
        RideRulesCheck.run()
        NotifierCheck.run()
        RideListCheck.run()
        HomeCheck.run()
        LiveScreenCheck.run()
        RideSummaryCheck.run()
        RouteCheck.runAll()
        MaintenanceCheck.run()
        CalibrationCheck.run(real: model.database)
        ChargeLogCheck.run(real: model.database)
        BackupWriteCheck.run()
        RideChecks.run(database: model.database)
        RideEngineCheck.runStart()
        RideEngineCheck.runEnd()
        RideEngineCheck.runTakeover()
        step = "Recorder: rides 1 and 2 into a temporary database"
        await RecorderCheck.run(real: model.database)

        if model.scooter.connected {
            summary.append("Simulator checks skipped: the real scooter is connected (switch it off and run again)")
        } else {
            let sim = model.simulator
            let saved = (sim.fixtureID, sim.scenarioID, sim.speed)
            step = "Simulator: ride 1"
            stepIndex = 6
            await simulate(fixture: "F2", scenario: SimScenario.clean.id)
            step = "Simulator: disconnect at 40%"
            stepIndex = 7
            await simulate(fixture: "F3", scenario: "D7")
            (sim.fixtureID, sim.scenarioID, sim.speed) = saved
        }

        stepIndex = 8
        step = OutsideProbes.shared.isOffline ? "Outside data (offline: e8)" : "Outside data"
        await OutsideProbes.shared.runAll()

        var lines = [String]()
        for id in Self.ids {
            let title = CheckList.item(id)?.title ?? id
            let note = results.note(id)
            lines.append("\(results.status(id).icon) \(id) \(title)" + (note.isEmpty ? "" : " — \(note)"))
        }
        let passed = Self.ids.filter { results.status($0) == .pass }.count
        summary.insert("\(passed) of \(Self.ids.count) automatic checks passed", at: 0)
        summary += lines
        Log.info(source: "developer", "Run all automatic: \(passed)/\(Self.ids.count) passed")
        step = ""
        stepIndex = 0
        running = false
    }

    /// Runs one simulator replay at 200× and waits for it to finish.
    private func simulate(fixture: String, scenario: String) async {
        let sim = AppModel.shared.simulator
        sim.fixtureID = fixture
        sim.scenarioID = scenario
        sim.speed = 200
        sim.start(realScooterConnected: AppModel.shared.scooter.connected)
        var waited = 0
        while sim.running && waited < 600 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        if sim.running { sim.stop(reason: "Stopped: took too long") }
    }
}
