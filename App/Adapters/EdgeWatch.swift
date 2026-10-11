import CorckieCore
import Foundation
import Observation
import UserNotifications

/// M6-06 (C28): the clock the recorder runs on, phone storage and the 7-day expiry. The rules are in Core (`ClockGuard`,
/// `StoragePolicy`, `AppExpiry`, unit tested); this applies them. Main thread (except `EngineClock`, which has its own lock).

/// The engine's time: the wall clock until somebody changes the wall clock; then the engine keeps its own timeline (a ride is not
/// cut, doubled or ended by a clock change) and the sensors' timestamps are mapped onto it. Re-anchored whenever no ride is on.
final class EngineClock: @unchecked Sendable {
    static let shared = EngineClock()
    private let lock = NSLock()
    private var clock = ClockGuard(wall: Date().timeIntervalSince1970, mono: EngineClock.monotonic())
    private var loggedJump = false
    /// Clock changes seen during the running ride (for the developer line)
    private(set) var jumpsThisRide = 0

    /// Seconds on a clock that keeps counting while the phone sleeps and ignores the wall clock being set
    static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return clock.now(mono: Self.monotonic())
    }

    /// A sensor timestamp (wall clock) on the engine's timeline
    func fromWall(_ date: Date) -> Double {
        lock.lock(); defer { lock.unlock() }
        return clock.engineTime(ofWall: date.timeIntervalSince1970, wall: Date().timeIntervalSince1970, mono: Self.monotonic())
    }

    /// Once a second. With no ride on, the clock is simply adopted; during a ride a change is logged once and the timeline kept.
    func check(rideActive: Bool) {
        lock.lock(); defer { lock.unlock() }
        let wall = Date().timeIntervalSince1970
        let mono = Self.monotonic()
        if !rideActive {
            clock.reanchor(wall: wall, mono: mono)
            loggedJump = false
            jumpsThisRide = 0
        } else if clock.isJump(wall: wall, mono: mono), !loggedJump {
            loggedJump = true
            jumpsThisRide += 1
            let jump = Int(clock.offsetS(wall: wall, mono: mono).rounded())
            DispatchQueue.main.async { Log.warning(source: "clock", "The phone clock changed by \(jump) s during a ride: the ride keeps its own timeline") }
        }
    }
}

@Observable
final class EdgeWatch {
    static let shared = EdgeWatch()
    /// Home cards: nil = nothing to say
    private(set) var expiryNotice: String?
    private(set) var storageNotice: String?
    private(set) var freeBytes: Int64?
    private static let reminderId = "app-expiry"
    private init() {}

    /// When the provisioning profile (the 7-day signature) ends; nil for builds without one
    static func expiryMs() -> Int64? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound,
              let object = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let dict = object as? [String: Any], let date = dict["ExpirationDate"] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    static func freeStorageBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// At Home, at launch and after a ride: storage (thin early, card when low) and the expiry reminder / card
    func refresh(database: AppDatabase?, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), expiryMs: Int64? = EdgeWatch.expiryMs(),
                 freeBytes free: Int64? = EdgeWatch.freeStorageBytes()) {
        freeBytes = free
        let level = StoragePolicy.level(freeBytes: free)
        storageNotice = StoragePolicy.homeNotice(level, freeBytes: free)
        if let database, !database.isReadOnly, let cutoff = StoragePolicy.thinCutoffMs(level, nowMs: nowMs) {
            let n = (try? RetentionService.thinEarly(database, cutoffMs: cutoff)) ?? 0
            if n > 0 { Log.info(source: "storage", "Phone storage low: \(n) old raw chunks removed early") }
        }
        let plan = AppExpiry.plan(expiryMs: expiryMs, nowMs: nowMs)
        expiryNotice = AppExpiry.homeNotice(plan)
        schedule(plan)
    }

    private func schedule(_ plan: AppExpiry.Plan) {
        let center = UNUserNotificationCenter.current()
        guard case .remind(let atMs) = plan else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.reminderId])
            return
        }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = AppExpiry.reminderTitle
            content.body = AppExpiry.reminderBody
            content.sound = .default
            let seconds = max(1, Double(atMs) / 1000 - Date().timeIntervalSince1970)
            center.add(UNNotificationRequest(identifier: Self.reminderId, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
        }
    }
}
