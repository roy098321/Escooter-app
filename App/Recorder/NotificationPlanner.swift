import CorckieCore
import Foundation

// M4-04: what the budgeted notifications say and whether they may go (Core `NotificationBudget`). The pieces that read the
// database live here (compiled into AppTests); the notification centre calls are in App/Notifier/BudgetedNotifier.swift.
// Budgeted: maintenance (M3-06), the weekly summary (Sunday 07:30), wind picking up (Q15-notify). Outside the budget:
// Going for a ride and the Arrive-by leave reminder. Every send and drop goes to `message_log` (reason on a drop).

enum NotificationPlanner {
    struct Weekly: Equatable {
        var fireMs: Int64
        var weekStart: Int64
        var title: String
        var body: String
    }

    struct Wind {
        var routeId: String
        var title: String
        var body: String
        var merge: InsightMerge
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func offsetMin() -> Int { TimeZone.current.secondsFromGMT() / 60 }

    // MARK: Budget counters

    /// Budgeted notifications already sent in the local day (maintenance, weekly, wind; Arrive-by and Going-for-a-ride are not counted)
    static func sentToday(_ db: AppDatabase, nowMs: Int64, utcOffsetMin: Int) -> Int {
        (try? MaintenanceQueries(db).notificationsSentToday(nowMs: nowMs, utcOffsetMin: utcOffsetMin)) ?? 0
    }

    /// The weekly summary is still to come in this local day: it keeps its place in the budget
    static func weeklyDueToday(_ db: AppDatabase, nowMs: Int64, utcOffsetMin: Int) -> Bool {
        guard let fire = scheduledWeeklyMs(db), fire > nowMs else { return false }
        let off = Int64(utcOffsetMin) * 60_000
        return (fire + off) / OutsideTime.dayMs == (nowMs + off) / OutsideTime.dayMs
    }

    static func windSentToday(_ db: AppDatabase, nowMs: Int64, utcOffsetMin: Int) -> Bool {
        let off = Int64(utcOffsetMin) * 60_000
        let dayStart = ((nowMs + off) / OutsideTime.dayMs) * OutsideTime.dayMs - off
        let rows = (try? MessageLogQueries(db).entries(type: BudgetedMessage.windPickingUp.logType)) ?? []
        return rows.contains { ($0.sentAt ?? 0) >= dayStart && ($0.sentAt ?? 0) < dayStart + OutsideTime.dayMs }
    }

    // MARK: Weekly (Sunday 07:30)

    private static let weeklyKey = "weekly.scheduledFor"
    private static let weeklyLoggedKey = "weekly.loggedFor"

    private static func int(_ db: AppDatabase, _ key: String) -> Int64? {
        guard let s = try? RideQueries(db).setting(key: key) else { return nil }
        return Int64(s)
    }

    static func scheduledWeeklyMs(_ db: AppDatabase) -> Int64? {
        guard let v = int(db, weeklyKey), v > 0 else { return nil }
        return v
    }

    static func markWeeklyScheduled(_ db: AppDatabase, fireMs: Int64) {
        try? RideQueries(db).setSetting(key: weeklyKey, json: String(fireMs))
    }

    /// The text for the next Sunday 07:30 about the 7 days before it ("Last week: ..."). nil: under 2 riding days, nothing to say
    /// (the budget then keeps no place). Rebuilt at every ride end and app open, so the numbers are the latest.
    static func weekly(_ db: AppDatabase, nowMs: Int64 = nowMs(), utcOffsetMin: Int = offsetMin()) -> Weekly? {
        let fire = NotificationBudget.nextWeeklyMs(nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        let start = NotificationBudget.weekStart(forFireMs: fire, utcOffsetMin: utcOffsetMin)
        let store = InsightQueries(db)
        let week = 7 * OutsideTime.dayMs
        guard let rides = try? store.weekRides(from: start, to: start + week) else { return nil }
        let before = (try? store.weekRides(from: start - week, to: start)) ?? []
        let prevKm: Double? = before.isEmpty ? nil : before.reduce(0.0) { $0 + $1.ride.distanceM } / 1000
        guard let q22 = InsightCatalogue.q22Weekly(weekStart: start, rides: rides.map(\.ride), previousWeekKm: prevKm, label: "Last week", nowMs: nowMs).first
        else { return nil }
        return Weekly(fireMs: fire, weekStart: start, title: NotificationBudget.weeklyTitle, body: q22.text)
    }

    /// App open: a weekly summary whose time has passed is logged as sent once (iOS delivered it; the budget counts it)
    static func logDeliveredWeekly(_ db: AppDatabase, nowMs: Int64 = nowMs()) {
        guard let fire = scheduledWeeklyMs(db), fire <= nowMs, int(db, weeklyLoggedKey) != fire else { return }
        _ = try? MessageLogQueries(db).add(type: BudgetedMessage.weeklySummary.logType, channel: "notification", at: fire, droppedReason: nil)
        try? RideQueries(db).setSetting(key: weeklyLoggedKey, json: String(fire))
        try? RideQueries(db).setSetting(key: weeklyKey, json: "0")
    }

    static func logDropped(_ db: AppDatabase, _ kind: BudgetedMessage, reason: String, nowMs: Int64 = nowMs()) {
        _ = try? MessageLogQueries(db).add(type: kind.logType, channel: "notification", at: nowMs, droppedReason: reason)
    }

    static func logSent(_ db: AppDatabase, _ kind: BudgetedMessage, nowMs: Int64 = nowMs()) {
        _ = try? MessageLogQueries(db).add(type: kind.logType, channel: "notification", at: nowMs, droppedReason: nil)
    }

    // MARK: Wind picking up (Q15-notify)

    /// A usual route (saved, rides on this weekday around now) whose forecast headwind is up: the text, or nil.
    /// The budget decision is made by the caller; `merge` is saved only when the message is sent.
    static func wind(_ db: AppDatabase, nowMs: Int64 = nowMs(), utcOffsetMin: Int = offsetMin()) -> Wind? {
        let routes = RouteQueries(db)
        let pooled = FactorEffects.forPooled(db)
        for route in ((try? routes.routes()) ?? []) where route.state == "saved" {
            let rows = ((try? routes.routeRides(routeId: route.id)) ?? []).filter { $0.kind == "ride" }
            let soon = NotificationBudget.likelyRideSoon(startsAtMs: rows.map(\.startAt), utcOffsetsMin: rows.map { $0.utcOffsetMin ?? utcOffsetMin },
                                                         nowMs: nowMs, utcOffsetMin: utcOffsetMin)
            guard soon else { continue }
            let stats = UsualRange.select(RouteCardLoader.stats(rows), nowMs: nowMs)
            let todayS = Geo.median(stats.compactMap(\.totalS)) ?? 900
            guard let hw = InsightRunner.forecastHeadwind(db, routeId: route.id, todayS: todayS, nowMs: nowMs) else { continue }
            let key = "wind.prev.\(route.id)"
            let previous = (try? RideQueries(db).setting(key: key)).flatMap { Double($0) }
            try? RideQueries(db).setSetting(key: key, json: String(hw))
            var perKm: [Double] = []
            for s in stats {
                if let used = s.usedPct, let d = s.distanceM, d > 0 { perKm.append(used / (d / 1000)) }
            }
            let found = InsightCatalogue.q15Notify(routeId: route.id, routeName: RouteService.title(routeId: route.id, database: db),
                                                   routeKm: (route.usualDistanceM ?? 0) / 1000, likelyRideSoon: true, forecastHeadwindKmh: hw,
                                                   previousForecastKmh: previous, pooledEffects: pooled, rangeKm: nil,
                                                   usualPctPerKm: Geo.median(perKm), nowMs: nowMs)
            guard let insight = found.first else { continue }
            let existing = (try? InsightQueries(db).existing(forRide: nil)) ?? []
            let merge = InsightDedupe.merge(candidates: [insight], existing: existing, nowMs: nowMs, summarySeen: false)
            guard !merge.insert.isEmpty else { continue }       // already today
            return Wind(routeId: route.id, title: NotificationBudget.windTitle, body: insight.text, merge: merge)
        }
        return nil
    }
}
