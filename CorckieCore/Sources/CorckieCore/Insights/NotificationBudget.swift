import Foundation

/// M4-04: the shared notification budget (CONCEPT "Message budget", CALC_SPEC 9.4, T98). One place decides for every
/// budgeted message: maintenance (M3-06), the weekly summary (Sunday 07:30) and "wind picking up" (Q15-notify).
/// Outside the budget (never counted, no quiet hours): "Going for a ride?" and the Arrive-by leave reminder (own rules).
/// Rules: never during a ride; quiet hours 22:00 to 07:00 (maintenance and wind are dropped, a maintenance item is checked again
/// at the next ride end; the weekly one is always at 07:30, outside them); at most 2 a day counting the weekly one when it is
/// due that day; wind picking up at most once a day. Pure logic; storage and the notification are in the App layer.

public enum BudgetedMessage: String, CaseIterable, Sendable {
    case maintenance
    case weeklySummary = "weekly_summary"
    case windPickingUp = "wind_picking_up"

    /// The `message_log` type
    public var logType: String { rawValue }

    /// The weekly summary is the one the budget keeps a place for
    public var isWeekly: Bool { self == .weeklySummary }
}

public enum BudgetDecision: Equatable, Sendable {
    case send
    case drop(reason: String)
}

public enum NotificationBudget {
    public static let weeklyWeekday = 0          // Sunday (DayClock: Sunday = 0)
    public static let weeklyMinuteOfDay = 7 * 60 + 30
    public static let perDay = T.t98NotificationsPerDay

    public static func isQuietHour(nowMs: Int64, utcOffsetMin: Int) -> Bool {
        let local = nowMs + Int64(utcOffsetMin) * 60_000
        let hour = Int(((local / 3_600_000) % 24 + 24) % 24)
        return hour >= T.t98QuietFromHour || hour < T.t98QuietToHour
    }

    /// `sentToday` = budgeted notifications already sent in the local day; `weeklyDueToday` = the weekly one is still to come today
    /// (it keeps its place); `windSentToday` = wind picking up already went today.
    public static func decide(_ kind: BudgetedMessage, nowMs: Int64, utcOffsetMin: Int, rideActive: Bool, sentToday: Int,
                              weeklyDueToday: Bool = false, windSentToday: Bool = false) -> BudgetDecision {
        if rideActive { return .drop(reason: "ride active") }
        if kind.isWeekly { return sentToday >= perDay + 1 ? .drop(reason: "daily limit") : .send }
        if isQuietHour(nowMs: nowMs, utcOffsetMin: utcOffsetMin) { return .drop(reason: "quiet hours") }
        if kind == .windPickingUp, windSentToday { return .drop(reason: "wind already today") }
        if sentToday + (weeklyDueToday ? 1 : 0) >= perDay { return .drop(reason: "daily limit") }
        return .send
    }

    /// The next Sunday 07:30 local time after `nowMs`.
    public static func nextWeeklyMs(nowMs: Int64, utcOffsetMin: Int) -> Int64 {
        let off = Int64(utcOffsetMin) * 60_000
        let day = OutsideTime.dayMs
        let localDay = Int64((Double(nowMs + off) / Double(day)).rounded(.down))
        let weekday = DayClock.weekday(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        let toSunday = Int64((7 - weekday + weeklyWeekday) % 7)
        var fire = (localDay + toSunday) * day + Int64(weeklyMinuteOfDay) * 60_000 - off
        if fire <= nowMs { fire += 7 * day }
        return fire
    }

    /// The finished week the notification of `fireMs` talks about: the 7 days before that Sunday.
    public static func weekStart(forFireMs fireMs: Int64, utcOffsetMin: Int) -> Int64 {
        InsightWeek.start(ms: fireMs, utcOffsetMin: utcOffsetMin) - 7 * OutsideTime.dayMs
    }

    /// Wind picking up: only when a ride is likely soon, so a usual ride on this weekday starts in the next 2 hours
    /// (at least 3 rides on this weekday in the history, start time within the window).
    public static func likelyRideSoon(startsAtMs: [Int64], utcOffsetsMin: [Int], nowMs: Int64, utcOffsetMin: Int) -> Bool {
        let weekday = DayClock.weekday(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        let nowMinute = DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        var n = 0
        for (i, at) in startsAtMs.enumerated() {
            let off = i < utcOffsetsMin.count ? utcOffsetsMin[i] : utcOffsetMin
            guard DayClock.weekday(startAtMs: at, utcOffsetMin: off) == weekday else { continue }
            let m = DayClock.minuteOfDay(startAtMs: at, utcOffsetMin: off)
            if m >= nowMinute && m <= nowMinute + 120 { n += 1 }
        }
        return n >= 3
    }

    public static let weeklyTitle = "Your week"
    public static let windTitle = "Wind picking up"
}
