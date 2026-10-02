import CorckieCore
import Foundation
import Observation
import UIKit

/// Composition root · ARCHITECTURE §2.2 #18: creates the real (or simulated) sources once
/// and hands them to the screens.
@Observable
final class AppModel {
    static let shared = AppModel()

    let scooter = ScooterLink()
    let simulator = SimulatorRunner()
    /// The real link's live path: decoder → plausibility → totals (same pipeline as the simulator)
    private(set) var live = ScooterPipeline()
    /// The one database (DATA_MODEL); nil only when opening failed
    private(set) var database: AppDatabase?
    /// V4: "Data update failed · Send report" instead of running on half-migrated data
    private(set) var databaseError: String?

    @ObservationIgnored private let started = Date()
    @ObservationIgnored private var launched = false

    private init() {}

    /// Called at every launch, also when iOS relaunches the app in the background for the
    /// scooter: the Bluetooth central must exist with the same restore ID straight away.
    func launch(options: [UIApplication.LaunchOptionsKey: Any]?) {
        guard !launched else { return }
        launched = true
        openDatabase()
        CrashCatcher.shared.start()
        ErrorLog.shared.trim()
        wireScooter()
        InstallChecks.run(database: database, error: databaseError)
        let relaunchedForBluetooth = options?[.bluetoothCentrals] != nil
        if relaunchedForBluetooth { Log.info(source: "launch", "Relaunched by iOS for the scooter") }
        if scooter.hasKnownScooter || relaunchedForBluetooth {
            scooter.start()
        }
    }

    /// Opens (and if needed migrates) the database before anything else (DATA_MODEL V1).
    func openDatabase() {
        guard database == nil, databaseError == nil else { return }
        do {
            database = try AppDatabase.openShared(build: AppInfo.build)
            if let copy = database?.preMigrationCopy {
                Log.info(source: "store", "Copy before migration: \(copy.lastPathComponent)")
            }
        } catch {
            databaseError = error.localizedDescription
        }
    }

    private func wireScooter() {
        scooter.connectHandlers.append { [weak self] inBackground in
            guard let self else { return }
            self.live.handle(TimedScooterEvent(t: self.seconds(), event: .connected))
            CheckResults.shared.passOnce("b1", "Connected to the scooter")
            if inBackground {
                CheckResults.shared.passOnce("c1", "Connected while the app was in the background")
                PhoneSensors.shared.start(fromWake: true)
            }
            if self.simulator.running {
                self.simulator.stop(reason: "Stopped: the real scooter connected")
            }
        }
        scooter.disconnectHandlers.append { [weak self] in
            guard let self else { return }
            self.live.handle(TimedScooterEvent(t: self.seconds(), event: .disconnected))
        }
        scooter.packetHandlers.append { [weak self] bytes, time, background in
            guard let self else { return }
            PacketLog.shared.add(bytes, at: time, background: background)
            self.live.handle(TimedScooterEvent(t: time.timeIntervalSince(self.started), event: .packet(bytes)))
            self.evaluateScooterChecks()
        }
    }

    private func seconds() -> Double { Date().timeIntervalSince(started) }

    /// b2–b4, c2: evaluated as packets arrive.
    private func evaluateScooterChecks() {
        let results = CheckResults.shared
        if live.packets >= 30, results.status("b2") == .pending, let f = live.frame,
           let v = f.voltage, let pct = f.batteryPct, let speed = f.speedKmh {
            let voltsOK = v >= T.t05MinVoltage && v <= T.t05MaxVoltage
            let pctOK = pct >= 0 && pct <= 100
            let ignored = live.plausibility.ignoredReadings
            let ok = voltsOK && pctOK && speed >= 0 && ignored == 0
            let temp: String = f.temperatureC.map { String(format: "%.0f °C", $0) } ?? "— °C (no reading yet)"
            let values: String = String(format: "%.1f km/h · %ld%% · %.2f V", speed, pct, v)
            let gear = "gear \(f.gear ?? 0) (cap \(f.capKmh ?? 0))"
            let note = "\(values) · \(temp) · \(gear) · ignored \(ignored)"
            results.set("b2", ok ? .pass : .fail, note)
        }
        let info = scooter.deviceInfo
        if results.status("b3") == .pending, info.firmware != nil, info.software != nil {
            if let change = info.change(from: .p2Baseline) {
                results.set("b3", .info, change)
                Log.warning(source: "scooter", change)
            } else {
                results.set("b3", .pass, info.fingerprint)
            }
        }
        if live.packets >= 20, results.status("b4") == .pending {
            let denied = scooter.deniedSeen.isEmpty ? "none offered" : scooter.deniedSeen.joined(separator: ", ")
            results.set("b4", .pass, "Subscribed to the data stream only; untouched command / firmware services: \(denied); the app has no write code")
        }
        if scooter.packetsInBackground >= 100 {
            results.passOnce("c2", "\(scooter.packetsInBackground) packets while locked")
        }
    }
}

/// a1, a3, a4, a6 at every launch.
enum InstallChecks {
    static func run(database: AppDatabase?, error: String?) {
        let results = CheckResults.shared
        let defaults = UserDefaults.standard
        results.passOnce("a1", "Opened build \(AppInfo.versionLine) on \(Date().formatted(date: .abbreviated, time: .shortened))")
        results.set("a3", AppInfo.bundleID == "com.corckieapp.app" ? .pass : .fail, AppInfo.bundleID)

        if let db = database {
            let migrations = (try? db.appliedMigrations())?.joined(separator: ", ") ?? "?"
            results.set("a6", db.isReadOnly ? .fail : .pass,
                        (db.isReadOnly ? "Read-only: data from a newer build · " : "") + "migrations: \(migrations)"
                        + (db.preMigrationCopy != nil ? " · copy made before migrating" : ""))
        } else {
            results.set("a6", .fail, error ?? "Database not open")
        }

        // a4: the app bundle moves to a new folder on every install / update / SideStore refresh.
        let path = Bundle.main.bundlePath
        let lastPath = defaults.string(forKey: "corckie.lastBundlePath")
        let lastBuild = defaults.string(forKey: "corckie.lastBuild") ?? "?"
        if let lastPath, lastPath != path, let meta = database?.meta {
            let kept = meta.launchCount > 1
            results.set("a4", kept ? .pass : .fail,
                        kept ? "Installed again (build \(lastBuild) → \(AppInfo.build)): install \(meta.installId.prefix(8)) kept, \(meta.launchCount) launches"
                             : "Installed again but the data was new (launch count \(meta.launchCount))")
        }
        defaults.set(path, forKey: "corckie.lastBundlePath")
        defaults.set(AppInfo.build, forKey: "corckie.lastBuild")
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.launch(options: launchOptions)
        return true
    }
}
