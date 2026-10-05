import Foundation

/// M2-07 (CALC_SPEC M29, T84): Arrive by. `leave = target - today(departure = leave) - margin`, margin = the usual range's upper
/// edge minus its median. Iterated up to 3 times until `leave` moves less than a minute (the rush-hour boundary changes today's
/// number when the leave time crosses it). M2 uses today's estimate in usual conditions; the forecast (M4) plugs into the same call.
public struct ArriveByPlan: Equatable, Sendable {
    public var targetAtMs: Int64
    public var leaveAtMs: Int64
    public var todayS: Double
    public var marginS: Double
    /// Passes made after the first guess (0 ... 3)
    public var iterations: Int
    public var rushHourAtLeave: Bool
    public var headline: String
    public var detail: String
}

public enum ArriveByResult: Equatable, Sendable {
    case notEnough(have: Int, need: Int)
    case plan(ArriveByPlan)

    public var plan: ArriveByPlan? {
        if case .plan(let p) = self { return p }
        return nil
    }
}

public enum ArriveBy {
    public static let maxIterations = 3
    static let convergedMs: Int64 = 60_000

    public static func plan(rides: [RouteRideStats], targetAtMs: Int64, utcOffsetMin: Int) -> ArriveByResult {
        func est(_ departureAtMs: Int64?) -> TodayResult {
            guard let at = departureAtMs else {
                return TodayEstimator.estimate(rides: rides, nowMs: targetAtMs, utcOffsetMin: utcOffsetMin)
            }
            return TodayEstimator.estimate(rides: rides, nowMs: at, utcOffsetMin: utcOffsetMin,
                                           departureMinute: DayClock.minuteOfDay(startAtMs: at, utcOffsetMin: utcOffsetMin))
        }
        func leave(_ e: TodayEstimate) -> Int64 { targetAtMs - Int64(((e.timeS + e.marginS) * 1000).rounded()) }

        // first guess: the usual departure for that day type
        guard case .estimate(var e) = est(nil) else {
            if case .notEnough(let have, let need) = est(nil) { return .notEnough(have: have, need: need) }
            return .notEnough(have: 0, need: T.t67EnoughTimeRides)
        }
        var at = leave(e)
        var passes = 0
        while passes < maxIterations {
            passes += 1
            guard case .estimate(let next) = est(at) else { break }
            e = next
            let moved = leave(next)
            let done = abs(moved - at) < convergedMs
            at = moved
            if done { break }
        }
        let rush = DayClock.isRushHour(weekday: DayClock.weekday(startAtMs: at, utcOffsetMin: utcOffsetMin),
                                       minuteOfDay: DayClock.minuteOfDay(startAtMs: at, utcOffsetMin: utcOffsetMin))
        let leaveText = clock(at, utcOffsetMin)
        let detail = "\(minutes(e.timeS)) min today + \(minutes(e.marginS)) min margin \u{00B7} to arrive by \(clock(targetAtMs, utcOffsetMin))"
        return .plan(ArriveByPlan(targetAtMs: targetAtMs, leaveAtMs: at, todayS: e.timeS, marginS: e.marginS, iterations: passes,
                                  rushHourAtLeave: rush, headline: "Leave by \(leaveText)", detail: detail))
    }

    /// The next time the clock shows `minuteOfDay` after `nowMs` (the picker has hours and minutes only)
    public static func nextTargetMs(minuteOfDay: Int, nowMs: Int64, utcOffsetMin: Int) -> Int64 {
        let offsetMs = Int64(utcOffsetMin) * 60_000
        let local = nowMs + offsetMs
        let dayStart = Int64((Double(local) / 86_400_000).rounded(.down)) * 86_400_000
        var target = dayStart + Int64(minuteOfDay) * 60_000
        if target <= local { target += 86_400_000 }
        return target - offsetMs
    }

    static func minutes(_ s: Double) -> Int { Int((s / 60).rounded()) }

    static func clock(_ ms: Int64, _ utcOffsetMin: Int) -> String {
        DayClock.clockText(minuteOfDay: DayClock.minuteOfDay(startAtMs: ms, utcOffsetMin: utcOffsetMin))
    }
}

/// What to do with the leave-by reminder: send it at the leave time, hold it to 07:00 when the leave time is in the quiet hours
/// (22:00 to 07:00, T98) and 07:00 is still before the target, or drop it. Arrive-by reminders are outside the 2 a day budget
/// (CALC_SPEC 9.4) and are never sent during a ride (the reminder is for before the ride).
public enum LeaveReminderDecision: Equatable, Sendable {
    case send(atMs: Int64, held: Bool)
    case drop(reason: String)
}

public enum LeaveReminder {
    public static let messageType = "leave_by"

    public static func decide(leaveAtMs: Int64, targetAtMs: Int64, nowMs: Int64, utcOffsetMin: Int, rideActive: Bool = false) -> LeaveReminderDecision {
        if rideActive { return .drop(reason: "ride active") }
        if leaveAtMs <= nowMs { return .drop(reason: "leave time already passed") }
        let hour = DayClock.minuteOfDay(startAtMs: leaveAtMs, utcOffsetMin: utcOffsetMin) / 60
        guard hour >= T.t98QuietFromHour || hour < T.t98QuietToHour else { return .send(atMs: leaveAtMs, held: false) }
        let offsetMs = Int64(utcOffsetMin) * 60_000
        let local = leaveAtMs + offsetMs
        var morning = Int64((Double(local) / 86_400_000).rounded(.down)) * 86_400_000 + Int64(T.t98QuietToHour) * 3_600_000
        if hour >= T.t98QuietFromHour { morning += 86_400_000 }
        let heldAt = morning - offsetMs
        if heldAt >= targetAtMs { return .drop(reason: "quiet hours, no longer relevant") }
        return .send(atMs: heldAt, held: true)
    }

    /// T84: a new leave time replaces the reminder when it is 2 min or more earlier (a later one is left alone: nobody is made late)
    public static func shouldReplace(oldLeaveAtMs: Int64?, newLeaveAtMs: Int64) -> Bool {
        guard let old = oldLeaveAtMs else { return true }
        return Double(old - newLeaveAtMs) >= T.t84ArriveByEarlierS * 1000
    }

    public static func text(destination: String, plan: ArriveByPlan, utcOffsetMin: Int) -> (title: String, body: String) {
        ("Time to leave",
         "Leave now to arrive at \(destination) by \(ArriveBy.clock(plan.targetAtMs, utcOffsetMin)) (about \(ArriveBy.minutes(plan.todayS)) min + \(ArriveBy.minutes(plan.marginS)) min margin).")
    }
}
