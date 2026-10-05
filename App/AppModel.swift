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
    /// What the screens read: the simulator's temporary database while a simulation is active (M1-15), else the real one
    var displayDatabase: AppDatabase? { ScreenSimulator.shared.database ?? database }
    /// V4: "Data update failed · Send report" instead of running on half-migrated data
    private(set) var databaseError: String?

    @ObservationIgnored private let started = Date()
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var fingerprintSaved = false

    private init() {}

    /// Called at every launch, also when iOS relaunches the app in the background for the
    /// scooter: the Bluetooth central must exist with the same restore ID straight away.
    func launch(options: [UIApplication.LaunchOptionsKey: Any]?) {
        guard !launched else { return }
        launched = true
        FieldChecks.shared.appLaunched()
        wireScooter()
        RecorderService.shared.start()      // M1-09: the 1-s tick runs from launch (also a background relaunch)
        // After a phone restart iOS can relaunch the app for the scooter BEFORE the first
        // unlock, when files and settings can't be read yet (c5). The Bluetooth part starts
        // now; everything that reads or writes data waits until it's readable.
        if UIApplication.shared.isProtectedDataAvailable {
            dataBecameAvailable()
        } else {
            NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                self?.dataBecameAvailable()
            }
        }
        let relaunchedForBluetooth = options?[.bluetoothCentrals] != nil
        if relaunchedForBluetooth { Log.info(source: "launch", "Relaunched by iOS for the scooter") }
        if scooter.hasKnownScooter || relaunchedForBluetooth {
            scooter.start()
        }
    }

    @ObservationIgnored private var dataReady = false

    private func dataBecameAvailable() {
        guard !dataReady else { return }
        dataReady = true
        CheckResults.shared.loadIfPossible()
        scooter.loadEventsIfPossible()
        openDatabase()
        if let db = database, !db.isReadOnly { RecorderService.shared.attach(db) }
        OutsideDataService.shared.refresh(database: database, reason: "app open")
        CrashCatcher.shared.start()
        ErrorLog.shared.trim()
        InstallChecks.run(database: database, error: databaseError)
        FieldChecks.shared.dataAvailable()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            PermissionsCheck.shared.refresh()
            FieldChecks.shared.checkDeliveredNotification()
            Notifier.shared.appBecameActive()
            OutsideDataService.shared.refresh(database: AppModel.shared.database, reason: "app open")
        }
        PermissionsCheck.shared.refresh()
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
            RecorderService.shared.scooterConnected(at: Date())
            CheckResults.shared.passOnce("b1", "Connected to the scooter")
            if inBackground {
                CheckResults.shared.passOnce("c1", "Connected while the app was in the background")
                PhoneSensors.shared.start(fromWake: true)
            }
            FieldChecks.shared.scooterConnected(inBackground: inBackground)
            C8Recorder.shared.linkUp(at: Date())
            if ScreenSimulator.shared.running { ScreenSimulator.shared.stop(reason: "Stopped: the real scooter connected") }
            if self.simulator.running {
                self.simulator.stop(reason: "Stopped: the real scooter connected")
            }
        }
        scooter.disconnectHandlers.append { [weak self] reason in
            guard let self else { return }
            self.live.handle(TimedScooterEvent(t: self.seconds(), event: .disconnected))
            RecorderService.shared.scooterDisconnected(at: Date())
            LastSeen.note(batteryPct: self.live.frame?.batteryPct, force: true)
            FieldChecks.shared.scooterDisconnected(reason: reason)
            C8Recorder.shared.linkDown(at: Date())
        }
        scooter.packetHandlers.append { [weak self] bytes, time, background in
            guard let self else { return }
            PacketLog.shared.add(bytes, at: time, background: background)
            RecorderService.shared.packet(bytes, at: time)
            PhoneSensors.shared.notePacket(at: time)
            C8Recorder.shared.packet(bytes, at: time, background: background)
            self.live.handle(TimedScooterEvent(t: time.timeIntervalSince(self.started), event: .packet(bytes)))
            self.evaluateScooterChecks()
            LastSeen.note(batteryPct: self.live.frame?.batteryPct)
            FieldChecks.shared.packet(batteryPct: self.live.frame?.batteryPct)
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
        // B03: keep the fingerprint in the `scooter` table, so exports after a relaunch have it
        if !fingerprintSaved, let fw = info.firmware, let sw = info.software, let db = database {
            do {
                try ScooterRecord.save(id: scooter.knownPeripheralID ?? "scooter", name: ScooterGatt.advertisedName,
                                       chip: info.model, firmware: fw, software: sw, in: db)
                fingerprintSaved = true
            } catch {
                Log.error(source: "store", "scooter fingerprint: \(error.localizedDescription)")
                fingerprintSaved = true
            }
        }
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
        // a3: SideStore (free account) appends the team ID: com.corckieapp.app.<TEAMID> (P4 F11)
        let base = "com.corckieapp.app"
        let id = AppInfo.bundleID
        if id == base {
            results.set("a3", .pass, id)
        } else if id.hasPrefix(base + ".") {
            results.set("a3", .pass, "\(base) + SideStore team suffix .\(id.dropFirst(base.count + 1))")
        } else {
            results.set("a3", .fail, id)
        }
        FuelPriceSetting.ensureDefault(database: database)

        // u2 (M1-01): version 0.6 and the decided thresholds
        let thresholdsOk = T.t99SlowKmh == 45 && T.t99ClearKmh == 43 && T.t101SafetyMarginShare == 0.10
        let line = "Version \(AppInfo.version) · speed warning on > \(Int(T.t99SlowKmh)) / off < \(Int(T.t99ClearKmh)) km/h · margin +\(Int((T.t101SafetyMarginShare * 100).rounded()))%"
        results.set("u2", thresholdsOk && AppInfo.version == "0.6" ? .pass : .fail, line)

        if let db = database {
            let migrations = (try? db.appliedMigrations())?.joined(separator: ", ") ?? "?"
            results.set("a6", db.isReadOnly ? .fail : .pass,
                        (db.isReadOnly ? "Read-only: data from a newer build · " : "") + "migrations: \(migrations)"
                        + (db.preMigrationCopy != nil ? " · copy made before migrating" : ""))
        } else {
            results.set("a6", .fail, error ?? "Database not open")
        }

        // a4: the app bundle moves to a new folder on every install / update / SideStore refresh.
        // a4 compares the database's install ID and launch count with what the previous
        // launch saw; it decides when the build number or the bundle folder changed.
        let path = Bundle.main.bundlePath
        let lastPath = defaults.string(forKey: "corckie.lastBundlePath")
        let lastBuild = defaults.string(forKey: "corckie.lastBuild")
        let lastInstall = defaults.string(forKey: "corckie.lastInstallId")
        let lastLaunches = defaults.integer(forKey: "corckie.lastLaunchCount")
        let reinstalled = (lastBuild != nil && lastBuild != AppInfo.build) || (lastPath != nil && lastPath != path)
        if reinstalled, let meta = database?.meta {
            let sameInstall = lastInstall == nil || lastInstall == meta.installId
            // Builds up to 19 didn't save the launch count: then the database must come from an
            // older build and have been opened before.
            let countKept = lastLaunches > 0
                ? meta.launchCount > lastLaunches
                : meta.launchCount > 1 && meta.createdBuild != AppInfo.build
            let ok = sameInstall && countKept
            let previousBuild: String = lastBuild ?? "?"
            let change: String = lastBuild == AppInfo.build ? "same build \(AppInfo.build) reinstalled" : "build \(previousBuild) → \(AppInfo.build)"
            let install: String = String(meta.installId.prefix(8))
            let wasInstall: String = lastInstall.map { String($0.prefix(8)) } ?? "?"
            let note: String
            if ok {
                note = "Updated (\(change)): install \(install) kept, launches \(lastLaunches) → \(meta.launchCount)"
            } else {
                note = "Updated (\(change)) but the data looks new: install \(install) (was \(wasInstall)), launches \(meta.launchCount) (was \(lastLaunches))"
            }
            results.set("a4", ok ? .pass : .fail, note)
        }
        defaults.set(path, forKey: "corckie.lastBundlePath")
        defaults.set(AppInfo.build, forKey: "corckie.lastBuild")
        if let meta = database?.meta {
            defaults.set(meta.installId, forKey: "corckie.lastInstallId")
            defaults.set(meta.launchCount, forKey: "corckie.lastLaunchCount")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.launch(options: launchOptions)
        return true
    }
}
