import ActivityKit
import CorckieCore
import Foundation
import Observation
import UserNotifications

/// F-31 / F-24: the charging timer. The owner taps Plugged in; from then on the shown % is the 13.6 %/h line (always "≈"), the
/// Live Activity, Home pill, Scooter card and two local notifications follow it, and the real % on the next scooter connect ends it.
/// Everything stays on the phone (P-2): the session and the log live in UserDefaults, notifications are local, no push server.
@MainActor @Observable
final class ChargeTimer {
    static let shared = ChargeTimer()

    /// nil = not charging
    private(set) var session: ChargeSession?
    /// Finished charges, newest first (kept 60)
    private(set) var log: [ChargeLogEntry] = []
    /// What the last unplugged timer estimated ("≈ 72 % when unplugged"), until a real reading replaces it
    private(set) var unplugged: (pct: Double, ms: Int64)?
    /// Refreshed every 30 s while the app runs (and on every read through `tick`)
    private(set) var nowMs: Int64 = ChargeTimer.clock()

    private static let sessionKey = "corckie.charge.session"
    private static let logKey = "corckie.charge.log"
    private static let unpluggedKey = "corckie.charge.unplugged"
    @ObservationIgnored private var timer: Timer?
    /// Tests and previews pin the clock
    @ObservationIgnored var clockOverride: Int64?
    /// ui-shots and checks never touch the real notification centre / Live Activity
    @ObservationIgnored var sideEffects = true

    static func clock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var now: Int64 { clockOverride ?? Self.clock() }
    var utcOffsetMin: Int { TimeZone.current.secondsFromGMT() / 60 }
    var charging: Bool { session != nil }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.sessionKey), let s = try? JSONDecoder().decode(ChargeSession.self, from: data) { session = s }
        if let data = d.data(forKey: Self.logKey), let l = try? JSONDecoder().decode([ChargeLogEntry].self, from: data) { log = l }
        if let v = d.array(forKey: Self.unpluggedKey) as? [Double], v.count == 2 { unplugged = (v[0], Int64(v[1])) }
    }

    /// Called once at launch: ticks every 30 s, and picks up a charge that was running when the app was closed.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
        if session != nil { Task { await schedule(); LiveActivityController.shared.sync(session, nowMs: now) } }
    }

    // MARK: Start, edit, end

    /// Plugged in is only for an offline scooter, and never during a ride (P-4: charging cannot overlap a ride anyway)
    var canStart: Bool { !AppModel.shared.scooter.connected && !RecorderService.shared.rideActive && session == nil }

    /// The last real reading the sheet pre-fills (nil: none yet, the owner types the start %)
    func lastReading() -> (pct: Int, ms: Int64)? {
        let l = LastSeen.load()
        guard let p = l.pct, let ms = l.ms else { return nil }
        return (p, ms)
    }

    /// The rider's numbers a target needs: blended %/km, reserve, and the usual trip (the named place most rides ended at, there and back)
    func context(scooterName: String) -> (pctPerKm: Double?, reserve: Double, usualNeed: Double?, usualName: String?) {
        guard let db = AppModel.shared.database else { return (nil, T.t80ReserveDefaultPct, nil, nil) }
        let o = BatteryOverview.load(db, currentPct: lastReading().map { Double($0.pct) } ?? 50, connected: false)
        let q = RouteQueries(db)
        var best: (name: String, need: Double, n: Int)?
        for p in (try? q.places()) ?? [] {
            guard let name = p.name, !name.isEmpty,
                  let rides = try? q.placeRides(placeId: p.id) else { continue }
            let used = rides.compactMap(\.usedPct).filter { $0 > 0 }
            guard used.count >= 3 else { continue }
            let sorted = used.sorted()
            let med = sorted[sorted.count / 2]
            if best == nil || used.count > best!.n { best = (name, med * 2, used.count) }
        }
        return (o.range?.pctPerKm, o.reservePct, best?.need, best?.name)
    }

    func begin(_ s: ChargeSession) {
        guard canStart || session != nil else { return }
        session = s
        unplugged = nil
        persist()
        afterChange()
    }

    /// New target / corrected start on a running timer (notifications are rescheduled)
    func update(_ s: ChargeSession) {
        guard session != nil else { return }
        session = s
        persist()
        afterChange()
    }

    /// "Unplugged": ends the timer, keeps the estimate as "≈ N % when unplugged"
    func unplug() {
        guard let s = session else { return }
        let entry = ChargeLogEntry.finish(s, atMs: now, realPct: nil)
        unplugged = (entry.endPct, entry.endMs)
        finish(entry)
    }

    /// The scooter connected and read a settled battery %: the real % replaces the estimate and ends the timer (logged as measured)
    func realReading(pct: Int) {
        unplugged = nil
        if let s = session { finish(ChargeLogEntry.finish(s, atMs: now, realPct: Double(pct))) } else { persist() }
    }

    private func finish(_ entry: ChargeLogEntry) {
        log.insert(entry, at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
        session = nil
        persist()
        cancelNotifications()
        LiveActivityController.shared.end()
    }

    func tick() {
        nowMs = now
        let link = AppModel.shared.scooter
        if sideEffects, session != nil, link.connected, let p = AppModel.shared.settledBatteryPct { realReading(pct: p); return }
        if let s = session { LiveActivityController.shared.sync(s, nowMs: nowMs) }
    }

    private func afterChange() {
        nowMs = now
        guard sideEffects else { return }
        Task { await schedule() }
        LiveActivityController.shared.sync(session, nowMs: now)
    }

    // MARK: Notifications (local, `.active`)

    func schedule() async {
        guard sideEffects, let s = session else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ChargeNotifications.allIds)
        let st = await center.notificationSettings().authorizationStatus
        guard st == .authorized || st == .provisional else { Log.info(source: "charge", "notifications not allowed"); return }
        for n in ChargeNotifications.plan(s, nowMs: now, utcOffsetMin: utcOffsetMin) {
            let c = UNMutableNotificationContent()
            c.title = n.title
            c.body = n.body
            c.sound = .default
            c.interruptionLevel = .active
            let secs = max(1, Double(n.atMs - now) / 1000)
            try? await center.add(UNNotificationRequest(identifier: n.id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)))
        }
        Log.info(source: "charge", "scheduled")
    }

    private func cancelNotifications() {
        guard sideEffects else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ChargeNotifications.allIds)
        center.removeDeliveredNotifications(withIdentifiers: ChargeNotifications.allIds)
    }

    // MARK: Storage

    private func persist() {
        let d = UserDefaults.standard
        if let s = session, let data = try? JSONEncoder().encode(s) { d.set(data, forKey: Self.sessionKey) } else { d.removeObject(forKey: Self.sessionKey) }
        if let data = try? JSONEncoder().encode(log) { d.set(data, forKey: Self.logKey) }
        if let u = unplugged { d.set([u.pct, Double(u.ms)], forKey: Self.unpluggedKey) } else { d.removeObject(forKey: Self.unpluggedKey) }
    }
}

/// The Live Activity on the lock screen / Dynamic Island: started with the timer, updated on every change and tick, ended with it.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<ChargeActivityAttributes>?

    func sync(_ s: ChargeSession?, nowMs: Int64) {
        guard ChargeTimer.shared.sideEffects else { return }
        guard let s else { end(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let full = Date(timeIntervalSince1970: Double(ChargeModel.fullMs(s)) / 1000)
        let zero = Date(timeIntervalSince1970: Double(s.startMs) / 1000 - s.startPct / ChargeModel.ratePctPerHour * 3600)
        let state = ChargeActivityAttributes.ContentState(zeroAt: zero, fullAt: full)
        let content = ActivityContent(state: state, staleDate: full.addingTimeInterval(3600))
        if activity == nil { activity = Activity<ChargeActivityAttributes>.activities.first }
        if let a = activity {
            Task { await a.update(content) }
        } else {
            let attrs = ChargeActivityAttributes(name: s.scooterName, pluggedAt: Date(timeIntervalSince1970: Double(s.startMs) / 1000))
            activity = try? Activity.request(attributes: attrs, content: content, pushType: nil)
            Log.info(source: "charge", activity == nil ? "live activity refused" : "live activity started")
        }
    }

    func end() {
        let all = Activity<ChargeActivityAttributes>.activities
        activity = nil
        for a in all { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
