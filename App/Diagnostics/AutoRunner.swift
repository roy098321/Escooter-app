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
    private(set) var summary: [String] = []

    /// The checks this button can settle
    static let ids = ["h1", "a3", "a6", "e1", "d6", "d9", "d1", "d7", "d8",
                      "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7"]

    func run() async {
        guard !running else { return }
        running = true
        summary = []
        let results = CheckResults.shared
        let model = AppModel.shared

        step = "Permissions"
        PermissionsCheck.shared.refresh()
        try? await Task.sleep(nanoseconds: 800_000_000)

        step = "App ID, database, fuel price setting"
        InstallChecks.run(database: model.database, error: model.databaseError)

        step = "Error log"
        let marker = "Automatic test entry \(UUID().uuidString.prefix(8))"
        Log.info(source: "developer", marker)
        let stored = model.database != nil && ErrorLog.shared.lines().contains { $0.hasSuffix(marker) }
        results.set("d6", stored ? .pass : .fail, stored ? "Stored in the database and read back" : "Not found in the database log")

        step = "Backup + restore"
        BackupRestoreTest.run()

        if model.scooter.connected {
            summary.append("Simulator checks skipped: the real scooter is connected (switch it off and run again)")
        } else {
            let sim = model.simulator
            let saved = (sim.fixtureID, sim.scenarioID, sim.speed)
            step = "Simulator: ride 1"
            await simulate(fixture: "F2", scenario: SimScenario.clean.id)
            step = "Simulator: disconnect at 40%"
            await simulate(fixture: "F3", scenario: "D7")
            (sim.fixtureID, sim.scenarioID, sim.speed) = saved
        }

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
