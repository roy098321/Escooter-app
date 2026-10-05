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

/// u34 (M4-05): the smart prompt and the Loaded tag. Core gates (5 rides, 2% unexplained, once a day, 2 dismissals pause 7 days) and,
/// in a temporary database, a ride that used 8 points more than the others: the card is asked, an answer changes the ride
/// (Heavy = 15 kg, Tyres soft = left out + tyre reminder due), the Loaded tag sets the kg, a second ride the same day is not asked.
enum SmartPromptCheck {
    static func run() {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let now: Int64 = 1_790_000_000_000
        let usual = UsualRangeValue(lo: 8, hi: 10, median: 9, n: 8, full: false)
        func card(rides: Int = 6, used: Double = 13, other: Double? = nil, state: SmartPromptState = SmartPromptState(), at: Int64 = now) -> SmartPromptCard? {
            SmartPrompt.card(rideId: "r", routeRides: rides, usedPct: used, usualUsed: usual, explanation: other.map { RideExplanation(items: [], otherPct: $0) },
                             state: state, nowMs: at, utcOffsetMin: 180)
        }
        let gates = card() != nil && card(rides: 4) == nil && card(used: 10.5) == nil && card(other: 1.9) == nil && card(other: 2) != nil
        let shown = SmartPrompt.afterShown(SmartPromptState(), rideId: "other", nowMs: now, utcOffsetMin: 180)
        let daily = card(state: shown) == nil && card(state: shown, at: now + 86_400_000) != nil
        let twice = SmartPrompt.afterDismiss(SmartPrompt.afterDismiss(SmartPromptState(), nowMs: now), nowMs: now)
        let pause = twice.pausedUntilMs == now + 7 * 86_400_000 && card(state: twice, at: now + 6 * 86_400_000) == nil && card(state: twice, at: now + 8 * 86_400_000) != nil
        let rulesOk = gates && daily && pause

        var dbOk = false
        var detail = "?"
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let r = try InsightSeed.promptRide(temp)
            let q = SmartPromptQueries(temp)
            try MaintenanceQueries(temp).insertMissing(Maintenance.defaults(odoKm: 100, nowMs: now).map(MaintenanceService.record))
            if let c = SmartPromptService.card(temp, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin) {
                SmartPromptService.shown(temp, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
                let askedAgain = SmartPromptService.card(temp, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin) != nil
                try SmartPromptService.answer(temp, rideId: r.lastRideId, .heavy, nowMs: r.nowMs)
                let a = try q.rideAnswer(r.lastRideId)
                let heavy = a?.loadKg == 15 && a?.promptAnswer == "heavy" && a?.excluded == false
                let notAgain = SmartPromptService.card(temp, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin) == nil
                try SmartPromptService.answer(temp, rideId: r.lastRideId, .tyresSoft, nowMs: r.nowMs)
                let soft = try q.rideAnswer(r.lastRideId)?.excluded == true
                let tyres = try MaintenanceQueries(temp).all().first { $0.id == "tyres" }
                let due = tyres.map { Maintenance.status(MaintenanceService.item($0), odoKm: 100, nowMs: r.nowMs).isDue } ?? false
                try SmartPromptService.setLoad(temp, rideId: r.lastRideId, level: .custom, kg: 7, nowMs: r.nowMs)
                let kg = try q.rideAnswer(r.lastRideId)
                dbOk = askedAgain && heavy && notAgain && soft && due && kg?.loadKg == 7 && kg?.loadLevel == "custom"
                detail = c.text
            }
        } catch {
            results.set("u34", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        results.set("u34", rulesOk && dbOk ? .pass : .fail,
                    "gates (5 rides, 2% unexplained) \(word(gates)) · once a day \(word(daily)) · 2 dismissals pause 7 days \(word(pause)) · "
                    + "simulated ride \"\(detail.prefix(44))\", Heavy = 15 kg, Tyres soft = left out + reminder due, Loaded tag, not asked twice \(word(dbOk))")
    }
}

/// u35 (M4-06): heat. Levels hot 90 / very hot 100 (once per level per ride, very hot stays: M1-07), the learned limit (2 protection events
/// move the warnings 5 °C below the lowest), and in a temporary database a hot ride: Peak card first (class safety), hot-day card.
enum HeatCheck {
    static func run() {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        var watch = HeatWatch()
        let first = watch.update(91), again = watch.update(92), veryHot = watch.update(101), stays = watch.update(95)
        let cooled = watch.update(80)
        let levelsOk = first == .hot && again == nil && veryHot == .veryHot && stays == nil && watch.level == .normal && cooled == nil
            && T.t47HotC == 90 && T.t47VeryHotC == 100
        let learned = HeatLimits.limits(eventTempsC: [78, 82])
        let learnedOk = learned.hotC == 73 && learned.veryHotC == 83 && HeatLimits.limits(eventTempsC: [78]).hotC == 90
        var dbOk = false
        var top = "?"
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let r = try InsightSeed.hotRide(temp)
            let ranked = try InsightQueries(temp).ranked(forRide: r.lastRideId, nowMs: r.nowMs + 60_000)
            let all = ([ranked.top].compactMap { $0 } + ranked.more)
            top = ranked.top?.text ?? "none"
            dbOk = ranked.top?.type == .heatPeak && ranked.top?.text == "Peak 93 \u{00B0}C \u{00B7} +68 \u{00B0}C"
                && all.contains { $0.type == .heatHotDay && $0.text.hasPrefix("Hot day (33") }
        } catch {
            results.set("u35", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        results.set("u35", levelsOk && learnedOk && dbOk ? .pass : .fail,
                    "hot 90 / very hot 100, once per level, very hot stays \(word(levelsOk)) · learned limit after 2 events \(word(learnedOk)) · "
                    + "simulated hot ride: top card \"\(top)\" + hot-day card \(word(dbOk))")
    }
}
