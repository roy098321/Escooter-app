import CorckieCore
import Foundation

/// u33 (M4-04): the shared message budget. Core rules (never during a ride, quiet hours, 2 a day with the weekly one keeping its
/// place, wind once a day, weekly Sunday 07:30) and the counters in a temporary database (weekly text from the simulated windy week,
/// logged once, drops carry their reason). Ends with this phone's message log.
enum BudgetCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let off = 180
        let day: Int64 = 20_000 * 86_400_000
        let noon = day + 9 * 3_600_000                 // 12:00 local
        let ride = NotificationBudget.decide(.maintenance, nowMs: noon, utcOffsetMin: off, rideActive: true, sentToday: 0) == .drop(reason: "ride active")
        let quiet = NotificationBudget.decide(.windPickingUp, nowMs: day + 20 * 3_600_000 + 30 * 60_000, utcOffsetMin: off, rideActive: false, sentToday: 0) == .drop(reason: "quiet hours")
        let limit = NotificationBudget.decide(.maintenance, nowMs: noon, utcOffsetMin: off, rideActive: false, sentToday: 2) == .drop(reason: "daily limit")
        let place = NotificationBudget.decide(.maintenance, nowMs: noon, utcOffsetMin: off, rideActive: false, sentToday: 1, weeklyDueToday: true) == .drop(reason: "daily limit")
        let wind = NotificationBudget.decide(.windPickingUp, nowMs: noon, utcOffsetMin: off, rideActive: false, sentToday: 0, windSentToday: true) == .drop(reason: "wind already today")
        let fire = NotificationBudget.nextWeeklyMs(nowMs: noon, utcOffsetMin: off)
        let weekday = DayClock.weekday(startAtMs: fire, utcOffsetMin: off)
        let minute = DayClock.minuteOfDay(startAtMs: fire, utcOffsetMin: off)
        let weeklyOk = weekday == 0 && minute == 450 && fire > noon && fire - noon <= 7 * 86_400_000
        let rulesOk = ride && quiet && limit && place && wind && weeklyOk

        var dbOk = false
        var text = "?"
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let r = try InsightSeed.windyWeek(temp, rides: 24)
            if let plan = NotificationPlanner.weekly(temp, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin) {
                text = plan.body
                NotificationPlanner.markWeeklyScheduled(temp, fireMs: plan.fireMs)
                NotificationPlanner.logDeliveredWeekly(temp, nowMs: plan.fireMs + 1000)
                NotificationPlanner.logDeliveredWeekly(temp, nowMs: plan.fireMs + 2000)
                NotificationPlanner.logDropped(temp, .maintenance, reason: "quiet hours", nowMs: plan.fireMs + 3000)
                let logged = try MessageLogQueries(temp).entries(type: "weekly_summary").count == 1
                let dropped = try MessageLogQueries(temp).entries(type: "maintenance").first?.droppedReason == "quiet hours"
                dbOk = plan.body.hasPrefix("Last week:") && logged && dropped
                    && NotificationPlanner.sentToday(temp, nowMs: plan.fireMs + 1000, utcOffsetMin: FactorSeed.utcOffsetMin) == 1
            }
        } catch {
            results.set("u33", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        var phone = "no data"
        if let real {
            let q = MessageLogQueries(real)
            let sent = ["maintenance", "weekly_summary", "wind_picking_up"].reduce(0) { $0 + ((try? q.entries(type: $1))?.filter { $0.sentAt != nil }.count ?? 0) }
            phone = "\(sent) budgeted notifications sent so far"
        }
        results.set("u33", rulesOk && dbOk ? .pass : .fail,
                    "never during a ride \(word(ride)) · quiet hours drop \(word(quiet)) · 2 a day \(word(limit)) · the weekly one keeps its place \(word(place)) · "
                    + "wind once a day \(word(wind)) · weekly Sunday 07:30 \(word(weeklyOk)) · weekly text \"\(text.prefix(40))\", logged once, drops carry the reason \(word(dbOk)) · this phone: \(phone)")
    }
}
