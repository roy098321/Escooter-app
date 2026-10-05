import CorckieCore
import Foundation
import GRDB

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
        let dayMs: Int64 = 7 * 86_400_000
        let weeklyOk: Bool = weekday == 0 && minute == 450 && fire > noon && fire - noon <= dayMs
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
        let g1: Bool = card() != nil && card(rides: 4) == nil && card(used: 10.5) == nil
        let g2: Bool = card(other: 1.9) == nil && card(other: 2) != nil
        let gates = g1 && g2
        let shown = SmartPrompt.afterShown(SmartPromptState(), rideId: "other", nowMs: now, utcOffsetMin: 180)
        let daily = card(state: shown) == nil && card(state: shown, at: now + 86_400_000) != nil
        let twice = SmartPrompt.afterDismiss(SmartPrompt.afterDismiss(SmartPromptState(), nowMs: now), nowMs: now)
        let pausedAt: Int64 = now + 7 * 86_400_000
        let p1: Bool = twice.pausedUntilMs == pausedAt
        let p2: Bool = card(state: twice, at: now + 6 * 86_400_000) == nil
        let p3: Bool = card(state: twice, at: now + 8 * 86_400_000) != nil
        let pause = p1 && p2 && p3
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
        let l1: Bool = first == .hot && again == nil && veryHot == .veryHot
        let l2: Bool = stays == nil && watch.level == .normal && cooled == nil
        let l3: Bool = T.t47HotC == 90 && T.t47VeryHotC == 100
        let levelsOk = l1 && l2 && l3
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

/// u36 (M4-07): the Stats numbers. Core: calendar week Sunday to Saturday, month, rolling, charges = sum of used % / 100 (short hops included),
/// electricity cost, fuel saved only over 2 km, holiday week without comparison. Database (temporary): the simulated week's totals equal
/// what the rides add up to.
enum StatsCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let off = 180
        let now: Int64 = 1_790_000_000_000
        let week = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let spanOk: Bool = week.endMs - week.startMs == 7 * 86_400_000
        let sundayOk: Bool = DayClock.weekday(startAtMs: week.startMs, utcOffsetMin: off) == 0
        let rolling = StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let rollingOk: Bool = rolling.startMs == now - 30 * 86_400_000
        let periodsOk = spanOk && sundayOk && rollingOk
        let prices = StatsPrices(packWh: 800, electricityIlsPerKwh: 0.64, fuelFallbackIls: 8.27, fuelLPer100km: 7)
        let start = week.startMs + 9 * 3_600_000
        let rides = [StatsRide(startAt: start, utcOffsetMin: off, kind: "ride", distanceM: 10_000, totalS: 900, usedPct: 12),
                     StatsRide(startAt: start + 3_600_000, utcOffsetMin: off, kind: "ride", distanceM: 1_500, totalS: 300, usedPct: 3),
                     StatsRide(startAt: start + 7_200_000, utcOffsetMin: off, kind: "shortHop", distanceM: 800, totalS: 200, usedPct: 1)]
        let t = StatsCalc.totals(rides, period: week, prices: prices, utcOffsetMin: off)
        let carCost: Double = 10.0 * 0.07 * 8.27
        let powerCost: Double = 12.0 * 0.008 * 0.64
        let fuel: Double = carCost - powerCost
        let wantCost: Double = 0.16 * 0.8 * 0.64
        let countsOk: Bool = t.rides == 2 && t.shortHops == 1
        let chargesOk: Bool = abs(t.charges - 0.16) < 0.0001 && abs(t.electricityIls - wantCost) < 0.0001
        let fuelOk: Bool = abs((t.fuelSavedIls ?? 0) - fuel) < 0.001
        let noPrice: Bool = StatsCalc.totals(rides, period: week, prices: StatsPrices(packWh: 800), utcOffsetMin: off).fuelSavedIls == nil
        let totalsOk = countsOk && chargesOk && fuelOk && noPrice
        let tagged = StatsCalc.holidayTagged(week, dayOffDates: [OutsideTime.day(week.startMs + 2 * 86_400_000 + Int64(off) * 60_000)], utcOffsetMin: off)
        let holidayOk = tagged && StatsCalc.comparisonPct(rides, span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off, holidayTagged: true) == nil

        var dbOk = false
        var detail = "?"
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let r = try InsightSeed.windyWeek(temp, rides: 24)
            let m = StatsLoader.load(temp, span: .month, mode: .rolling, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
            let from = r.nowMs - 30 * 86_400_000
            let sums = try temp.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, SUM(distanceM) AS d, SUM(usedPct) AS u FROM ride WHERE startAt >= ? AND startAt < ?", arguments: [from, r.nowMs + 1])
            }
            let n: Int = sums?["n"] ?? -1
            let d: Double = sums?["d"] ?? -1
            let u: Double = sums?["u"] ?? -1
            dbOk = n > 0 && m.totals.rides == n && abs(m.totals.km - d / 1000) < 0.01 && abs(m.totals.charges - u / 100) < 0.0001
                && m.totals.barsKm.count == 30 && abs(m.totals.barsKm.reduce(0, +) - d / 1000) < 0.01
            detail = "\(m.totals.rides) rides, \(StatsCalc.km(m.totals.km)), \(StatsCalc.charges(m.totals.charges)) charges"
        } catch {
            results.set("u36", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        var phone = "no data"
        if let real {
            let m = StatsLoader.load(real, span: .week, mode: .calendar)
            phone = "this week \(m.totals.rides) rides, \(StatsCalc.km(m.totals.km)), \(StatsCalc.charges(m.totals.charges)) charges"
        }
        results.set("u36", periodsOk && totalsOk && holidayOk && dbOk ? .pass : .fail,
                    "week Sunday to Saturday, rolling \(word(periodsOk)) · charges, electricity, fuel only over 2 km \(word(totalsOk)) · holiday week no comparison \(word(holidayOk)) · "
                    + "simulated rides add up (\(detail)) \(word(dbOk)) · this phone: \(phone)")
    }
}

/// u37 (M4-08 / M4-09): the Factors page rows and the weekly summary. Core: an effect shows "based on N rides", below its gate only the
/// progress line; database (temporary): the simulated week gives the headwind row with its effect at 24 rides and "2 of 3 windy rides"
/// at 4, the week card and the past weeks are made from the rides, a week with one riding day has no summary.
enum WeekAndFactorsCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let pass = FactorsPage.rows([InsightSamples.effect("W1", "head", .time, 60, scope: .pooled), InsightSamples.effect("W1", "head", .used, 0.3, scope: .pooled)])
        let below = FactorsPage.rows([InsightSamples.effect("W1", "head", .time, nil, n: 2, nWithout: 5)])
        let r1: Bool = pass.first?.timeText == "+1 min per km" && pass.first?.basedOn == "based on 12 rides"
        let r2: Bool = below.first?.progress == "2 of 3 windy rides" && below.first?.timeText == nil && below.first?.batteryText == nil
        let r3: Bool = FactorsPage.answerRows(counts: [.tyresSoft: 3]).count == 1 && FactorsPage.answerRows(counts: [.tyresSoft: 2]).isEmpty
        let rowsOk = r1 && r2 && r3

        var dbOk = false
        var detail = "?"
        do {
            let a = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { a.discardTemporary() }
            let r = try InsightSeed.windyWeek(a, rides: 24)
            let rows = FactorsPage.rows(FactorEffects.forRoute(a, routeId: InsightSeed.routeId))
            let effectOk = rows.contains { $0.title == "Headwind" && $0.hasEffect && ($0.basedOn ?? "").hasPrefix("based on") }
            let past = InsightRunner.pastWeeks(a, nowMs: r.nowMs + 14 * 86_400_000, utcOffsetMin: FactorSeed.utcOffsetMin)
            let m = StatsLoader.load(a, span: .week, mode: .calendar, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
            let cardOk = (m.lastWeek + m.thisWeek).contains { $0.type == .q22Weekly } && !past.isEmpty && past.allSatisfy { ($0.lines.first ?? "").hasPrefix("Week of ") }

            let b = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { b.discardTemporary() }
            _ = try InsightSeed.windyWeek(b, rides: 4)
            let few = FactorsPage.rows(FactorEffects.forRoute(b, routeId: InsightSeed.routeId))
            let sparseOk = few.allSatisfy { !$0.hasEffect } && few.contains { $0.progress == "2 of 3 windy rides" }

            let c = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { c.discardTemporary() }
            let ids = try FactorSeed.commute(c, routeId: "seed-route", n: 1)
            let start = InsightWeek.start(ms: try InsightQueries(c).ride(ids[0])?.startAt ?? 0, utcOffsetMin: FactorSeed.utcOffsetMin)
            let oneDay = try InsightRunner.weekCandidates(c, start: start, label: "Week", nowMs: start + 8 * 86_400_000).isEmpty
            dbOk = effectOk && cardOk && sparseOk && oneDay
            detail = "headwind row \(word(effectOk)), week card + \(past.count) past weeks \(word(cardOk)), 4 rides = progress only \(word(sparseOk)), 1 riding day = no summary \(word(oneDay))"
        } catch {
            results.set("u37", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        var phone = "no data"
        if let real {
            let rows = FactorsPage.rows(FactorEffects.forPooled(real))
            phone = "\(rows.filter(\.hasEffect).count) factor effects shown, \(rows.filter { $0.progress != nil }.count) still collecting"
        }
        results.set("u37", rowsOk && dbOk ? .pass : .fail,
                    "factor rows: effect + \"based on N rides\", progress below the gate \(word(rowsOk)) · \(detail) · this phone: \(phone)")
    }
}
