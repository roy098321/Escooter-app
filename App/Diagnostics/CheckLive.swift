import CorckieCore
import CorckieSim
import Foundation

/// M1-00b: what a running check shows on the Checks screen: a progress bar (timed or counted
/// checks) or a step list that ticks itself (multi-step checks). The arithmetic and the step
/// lists live in CorckieCore (`CheckProgress`, tested on Linux); this only reads the live state.
@MainActor
enum CheckLive {
    static let timedRecordingSeconds = 1200.0

    /// A bar while the check is running (nil = nothing running for this check).
    static func bar(_ id: String, now: Date = Date()) -> CheckBar? {
        let results = CheckResults.shared
        let passed = results.status(id) == .pass
        switch id {
        case "b8":
            let f = FieldChecks.shared
            guard f.stabilityRunning else { return nil }
            return CheckProgress.timed(elapsed: Double(f.stabilityElapsed), total: Double(FieldChecks.stabilitySeconds))
        case "c8":
            guard let since = PhoneSensors.shared.recordingSince else { return nil }
            return CheckProgress.timed(elapsed: now.timeIntervalSince(since), total: timedRecordingSeconds)
        case "c2":
            let n = AppModel.shared.scooter.packetsInBackground
            return passed || n == 0 ? nil : CheckProgress.counted(have: n, need: 100, noun: "packets while locked")
        case "c3":
            let n = PhoneSensors.shared.fixesInBackground
            return passed || n == 0 ? nil : CheckProgress.counted(have: n, need: 20, noun: "fixes while locked")
        case "c4":
            let n = PhoneSensors.shared.altitudeInBackground
            return passed || n == 0 ? nil : CheckProgress.counted(have: n, need: 20, noun: "readings while locked")
        case "d1", "d7", "d8":
            let sim = AppModel.shared.simulator
            guard sim.running else { return nil }
            let wanted = id == "d7" ? sim.runScenarioID == "D7" : (id == "d1" ? sim.runScenarioID == SimScenario.clean.id : true)
            guard wanted else { return nil }
            let left = max(0, 1 - sim.progress)
            return CheckBar(fraction: sim.progress, label: String(format: "%.0f%% · simulated ride at %.0f×", sim.progress * 100, sim.runSpeed) + (left > 0 ? "" : " · done"))
        case "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7", "e8":
            let probes = OutsideProbes.shared
            guard probes.running else { return nil }
            return CheckProgress.counted(have: probes.probesDone, need: OutsideProbes.probesPerRun, noun: "sources asked")
        default:
            return nil
        }
    }

    /// "Run all automatic": step i of 7.
    static func autoBar() -> CheckBar? {
        let auto = AutoRunner.shared
        guard auto.running else { return nil }
        return CheckProgress.stepped(index: auto.stepIndex, of: AutoRunner.stepCount, name: auto.step)
    }

    /// A self-ticking step list for the multi-step checks (nil = a one-step check).
    static func steps(_ id: String) -> [CheckStep]? {
        let results = CheckResults.shared
        let passed = results.status(id) == .pass
        let f = FieldChecks.shared
        switch id {
        case "b9":
            return CheckProgress.b9(armed: f.rangeArmed || f.rangeLost || passed, locked: f.rangeLocked || passed,
                                    disconnected: f.rangeLost || passed, reconnected: f.rangeBack || passed, withoutOpening: passed)
        case "c5":
            return CheckProgress.c5(restarted: f.restartSeen || passed, startedInBackground: f.startedInBackground || passed,
                                    scooterConnected: f.wakeSeen || passed, passed: passed)
        case "c6":
            return CheckProgress.c6(scooterWoke: f.wakeSeen || passed, sent: f.notificationSent || passed, delivered: passed)
        case "c7":
            return CheckProgress.c7(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled || passed, woke: f.lowPowerWoke || passed, enoughData: passed)
        default:
            return nil
        }
    }
}
