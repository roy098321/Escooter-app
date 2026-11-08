import CorckieCore
import Foundation
import GRDB
import UserNotifications

/// V-U2 (batch 3): the battery decay report and its notices. Checked when a ride closes and when the app opens; never during a ride
/// (P-4): a notice found while riding waits for the next check. Each level is sent once; "I replaced the battery" starts over.
enum BatteryDecayService {
    static let sentKey = "vu2.sentLevels"
    static let resetKey = "vu2.resetAt"
    static let noticeId = "battery_decay"

    static func rides(_ db: AppDatabase) -> [DecayRide] {
        (try? db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT startAt, distanceM, usedPct, airTempC FROM ride
                WHERE kind = 'ride' AND isSimulated = 0 AND endAt IS NOT NULL AND distanceM > 0 AND usedPct > 0
                ORDER BY startAt
                """).map { r in
                DecayRide(startAt: r["startAt"], distanceM: r["distanceM"], usedPct: r["usedPct"], airTempC: r["airTempC"])
            }
        }) ?? []
    }

    static func resetAt(_ db: AppDatabase) -> Int64? {
        (try? RideQueries(db).setting(key: resetKey)).flatMap { $0 }.flatMap { Int64($0) }
    }

    static func report(_ db: AppDatabase, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> DecayReport {
        BatteryDecay.report(rides: rides(db), nowMs: nowMs, resetAtMs: resetAt(db))
    }

    static func sent(_ db: AppDatabase) -> Set<Int> {
        guard let s = (try? RideQueries(db).setting(key: sentKey)).flatMap({ $0 }) else { return [] }
        return Set(s.split(separator: ",").compactMap { Int($0) })
    }

    /// After a ride closes / at app open: send the deepest new level (not while riding)
    static func check(_ db: AppDatabase?) {
        guard let db, !db.isReadOnly, !RecorderService.shared.rideActive else { return }
        let r = report(db)
        guard let level = BatteryDecay.noticeLevel(report: r, sent: sent(db)) else { return }
        // a deeper level also counts the shallower ones as sent (one notice, the newest news)
        let all = sent(db).union(stride(from: BatteryDecay.firstLevel, through: level, by: -BatteryDecay.step))
        try? RideQueries(db).setSetting(key: sentKey, json: all.sorted().map(String.init).joined(separator: ","))
        let words = BatteryDecay.notice(level: level, report: r)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = words.title
            content.body = words.body
            content.sound = .default
            content.userInfo = ["open": "batteryReport"]
            center.add(UNNotificationRequest(identifier: noticeId, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
        }
        Log.info(source: "battery", "V-U2: level \(level) notice (\(words.title))")
    }

    /// "I replaced the battery": a new baseline from now; levels can be sent again
    static func replaced(_ db: AppDatabase?) {
        guard let db, !db.isReadOnly else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? RideQueries(db).setSetting(key: resetKey, json: String(now))
        try? RideQueries(db).setSetting(key: sentKey, json: "")
        Log.info(source: "battery", "V-U2: battery replaced, new baseline from now")
    }
}
