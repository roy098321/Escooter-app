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
    static let ids = AutomaticChecks.ids

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
        UpdateCheck.run()
        IdleBatteryCheck.run()

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
        RealRangeCheck.run(real: model.database)
        await OutsideDataCheck.run(real: model.database)
        FactorCheck.run(real: model.database)
        InsightCheck.run(real: model.database)
        BudgetCheck.run(real: model.database)
        SmartPromptCheck.run()
        HeatCheck.run()
        StatsCheck.run(real: model.database)
        WeekAndFactorsCheck.run(real: model.database)
        RideToolsCheck.run(real: model.database)
        await ReplayCheck.run()
        ExportRestoreCheck.run(real: model.database)
        SettingsCheck.run(real: model.database)
        FastestCheck.run(real: model.database)
        EdgeCheck.run()
        FieldKitCheck.run()
        AccuracyCheck.run()
        ShadowCheck.run()
        ScenarioCheck.run()
        step = "Screens and states: drawing every ui-shot screen"
        await StatesCheck.run()
        BackupWriteCheck.run()
        RideChecks.run(database: model.database)
        RideEngineCheck.runStart()
        RideEngineCheck.runEnd()
        RideEngineCheck.runTakeover()
        step = "Recorder: rides 1 and 2 into a temporary database"
        await RecorderCheck.run(real: model.database)
        // P6-1 fixes (B24 places / way back / re-link, B25 sample columns, B26 scooter off, B27 live battery)
        P61Checks.runPlaces(real: model.database)
        await P61Checks.runSampleColumns()
        P61Checks.runScooterOff()
        P61Checks.runLiveBattery()
        P64C2Checks.run()                        // P6-4 chunk 2: u80 places as destinations, u81 quick dial + icons, u82 parked newest wins, u83 odometer gap
        P65Checks.run()                          // P6-5: u110 place estimates (B44, B45, B46), u111 boot battery reading (B50), u112 Past weeks metrics, photo frame, pins
        P64C3Checks.run()                        // P6-4 chunk 3: u90 info sheets add up (B32), u91 Past weeks buckets (B33), u92 scooter colour stored
        P64C3bChecks.run()                       // P6-4 chunk 3b (F-21): u100 sweet spot, u101 departure + creep, u102 wind, u103 certainty gate
        B101Checks.run()                         // batch 101 chunk A: u130 battery flip filter (B56), u131 phone rides kept (B57), u132 settled ride battery (B54), u133 end at last movement (F-38), u134 riding start (B62), u135 what is a ride (F-39), u136 bad readings (notes 12 + 10); chunk B: u137 destination during the ride (F-35), u138 ride kept open while connected or moving (B63), u139 Scooter-on destination buttons (F-36), u140 one Where to? row per destination (B61), u141 fresh arrival time (B58), u142 time and battery (note 14)
        ChargeEtaChecks.run()                    // P6-6 (F-31 / F-27): u120 charge timer maths, u121 targets + notification times, u122 charge log data
        P61UiChecks.run(real: model.database)   // chunk 2: u55 bounce, u56 live tiles + camera, u57 saved way back
        await P61PlaceChecks.run()               // chunk 3: u58 place colours, u59 places by hand + labels, u60 street lookup
        P62Checks.run()                          // P6-2 chunk 1: u61 theme, u62 tab bar hides on scroll, u64 Home and live view declutter (chunk 2a), u65 Rides list and ride detail declutter (chunk 2b), u66 Stats / Battery / Routes / Settings declutter (chunk 3)
        P63AliveChecks.run()                     // P6-3 chunk 3: u74 battery warnings, u75 F-22, u76 sound files, u77 audio session
        P63Checks.run()                          // P6-3 chunk 1: u67 Add a place, u68 map screens, u69 Home, u70 rolling stats, u71 saved per km + weekly line, u72 parked, u73 quiet live view
        P64Checks.run()                          // P6-4 chunk 1: u78 Replay / ride charts maths (B37, B38, B39, cursor)

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
        UpdateCheck.justUpdated = false
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

/// The IDs "Run all automatic" settles by itself (T-01: also what the check list calls Automatic).
enum AutomaticChecks {
    static let ids: [String] = ["h1", "a3", "a6", "u2", "u3", "u4", "u5", "u6", "u7", "u8", "u9", "u10", "u11", "u12", "u13", "u14", "u15", "u16", "u17", "u18", "u19", "u20", "u21", "u22", "u23", "u24", "u25", "u26", "u27", "u28", "u29", "u30", "u31", "u32", "u33", "u34", "u35", "u36", "u37", "u38", "u39", "u40", "u41", "u42", "u44", "u45", "u46", "u47", "u48", "u49", "u50", "u51", "u52", "u53", "u54", "u55", "u56", "u57", "u58", "u59", "u60", "u61", "u62", "u64", "u65", "u66", "u67", "u68", "u69", "u70", "u71", "u72", "u73", "u74", "u75", "u76", "u77", "u78", "a9", "o1", "e1", "d6", "d9", "d1", "d7", "d8",
                      "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7",
                      "u80", "u81", "u82", "u83", "u90", "u91", "u92",
                      "u100", "u101", "u102", "u103", "u110", "u111", "u112", "u120", "u121", "u122",
                      "u130", "u131", "u132", "u133", "u134", "u135", "u136",
                      "u137", "u138", "u139", "u140", "u141", "u142"]
}
