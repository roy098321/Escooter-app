import CorckieCore
import Foundation

/// u32 (M4-03): the insight catalogue. Core: every catalogue row speaks with made-up numbers and none uses reward language
/// (P-3); gates (just below / at); ranking (class + size, freshness), N more, the ride-start pick (2, C24 order), Recent order.
/// Database (temporary, the "simulated windy week"): 4 rides = the progress line only, 24 rides = the wind credit; a re-run
/// makes no duplicate ids; a late card for a seen summary goes to Recent only; the week card is built. Ends with this phone's rows.
enum InsightCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }

        // 1. Core: every type speaks, no reward words
        let samples = InsightSamples.all()
        let typesOk = Set(samples.map(\.type)) == Set(InsightType.allCases)
        let banned = samples.filter { !InsightText.bannedIn($0.text).isEmpty }
        let wordingOk = banned.isEmpty && !InsightText.bannedIn("New personal best").isEmpty

        // 2. gates: Q15-after progress at 2 windy rides, credit once the effect passes; Q22 needs 2 riding days
        let now = InsightSamples.now
        let below = InsightCatalogue.q15After(rideId: "r", routeId: "A", routeName: nil, rideHeadwindKmh: 12, explanation: nil,
                                              routeEffects: [InsightSamples.effect("W1", "head", .time, nil, n: 2, nWithout: 5)], nowMs: now)
        let at = InsightCatalogue.q15After(rideId: "r", routeId: "A", routeName: nil, rideHeadwindKmh: 12,
                                           explanation: RideExplanation(items: [.init(factorId: "W1", level: "head", timeS: 60, usedPct: nil, confidence: 0.7)]),
                                           routeEffects: [InsightSamples.effect("W1", "head", .time, 60)], nowMs: now)
        let oneDay = WeekRide(startAt: now, utcOffsetMin: 0, kind: "ride", distanceM: 5_000, totalS: 900)
        let gateOk = below.first?.isProgress == true && below.first?.text.contains("2 of 3 windy rides") == true
            && at.first?.isProgress == false
            && InsightCatalogue.q22Weekly(weekStart: 0, rides: [oneDay, oneDay], previousWeekKm: nil, nowMs: now).isEmpty

        // 3. ranking, freshness, N more, start pick, recent
        func mk(_ t: InsightType, _ s: Double, at: Int64? = nil) -> Insight {
            Insight(type: t, rideId: "r", routeId: "A", text: t.rawValue, basedOnN: 5, timeS: s, createdAt: at ?? InsightSamples.now)
        }
        let ranked = InsightRanking.rank([mk(.q15After, 60), mk(.q4After, 30), mk(.q1After, 240)], recentTopTypes: [], nowMs: now)
        let fresh = InsightRanking.rank([mk(.q4After, 30), mk(.q1After, 240)], recentTopTypes: [.q4After], nowMs: now)
        let pick = InsightRanking.startPick([mk(.q15Live, 0), mk(.q1Live, 0), mk(.q9Live, 0)])
        let recent = InsightRanking.recent([mk(.q4After, 0, at: now), mk(.q15After, 0, at: now + 5)])
        let rankOk = ranked.top?.type == .q4After && ranked.more.map(\.type) == [.q1After, .q15After] && fresh.top?.type == .q1After
            && pick.shown.map(\.type) == [.q9Live, .q1Live] && pick.toSummary.map(\.type) == [.q15Live] && recent.first?.type == .q15After

        // 4. the database: the simulated windy week, below and above the gate
        var belowOk = false, aboveOk = false, dedupeOk = false, lateOk = false, weekOk = false
        var aboveText = "?"
        do {
            let a = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { a.discardTemporary() }
            let r4 = try InsightSeed.windyWeek(a, rides: 4)
            let rows4 = try InsightQueries(a).ranked(forRide: r4.lastRideId, nowMs: r4.nowMs)
            belowOk = rows4.top == nil && rows4.progress.contains { $0.type == .q15After && $0.text.contains("2 of 3 windy rides") }

            let b = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { b.discardTemporary() }
            let r24 = try InsightSeed.windyWeek(b, rides: 24)
            let store = InsightQueries(b)
            let rows = try store.ranked(forRide: r24.lastRideId, nowMs: r24.nowMs)
            let credit = ([rows.top].compactMap { $0 } + rows.more).first { $0.type == .q15After }
            aboveText = credit?.text ?? "none"
            aboveOk = credit?.text.hasPrefix("Tailwind saved you") == true && rows.progress.allSatisfy { $0.type != .q15After }
            // re-run: same ids, nothing new
            let before = try store.forRide(r24.lastRideId).map(\.id)
            let again = try InsightRunner.afterRide(b, rideId: r24.lastRideId, nowMs: r24.nowMs + 60_000)
            let after = try store.forRide(r24.lastRideId).map(\.id)
            dedupeOk = again.inserted == 0 && Set(after) == Set(before) && Set(before).count == before.count
            // the summary was seen, then a card comes late (weather arrives): Recent only
            try store.markShown(rideId: r24.lastRideId, at: r24.nowMs)
            if let id = credit?.id {
                try b.writer.write { db in try db.execute(sql: "DELETE FROM insight WHERE id = ?", arguments: [id]) }
                try InsightRunner.afterRide(b, rideId: r24.lastRideId, nowMs: r24.nowMs + 120_000)
                let late = try store.forRide(r24.lastRideId).first { $0.id == id }
                let inRecent = try store.recent().contains { $0.id == id }
                let topId = try store.top(forRide: r24.lastRideId, nowMs: r24.nowMs + 120_000)?.id
                lateOk = late?.moment == .recentOnly && inRecent && topId != id
            }
            let ws = InsightWeek.start(ms: r24.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
            let cards = try store.weekCard(weekStart: ws) + store.weekCard(weekStart: ws - 7 * OutsideTime.dayMs)
            weekOk = cards.contains { $0.type == .q22Weekly }
        } catch {
            results.set("u32", .fail, "The simulated windy week failed: \(error.localizedDescription)")
            return
        }

        let ok = typesOk && wordingOk && gateOk && rankOk && belowOk && aboveOk && dedupeOk && lateOk && weekOk
        var phone = "no data"
        if let real, let c = try? InsightQueries(real).count() {
            phone = "\(c.rows - c.progress) insights, \(c.progress) progress lines"
        }
        results.set("u32", ok ? .pass : .fail,
                    "every catalogue row speaks \(word(typesOk)) · no reward words (P-3) \(word(wordingOk))\(banned.isEmpty ? "" : " (\(banned.map(\.type.rawValue).joined(separator: ", ")))") · "
                    + "gates (2 of 3 windy rides, 2 riding days) \(word(gateOk)) · ranking, freshness, N more, start pick 2, Recent by time \(word(rankOk)) · "
                    + "windy week: 4 rides = progress line \(word(belowOk)), 24 rides = \"\(aboveText)\" \(word(aboveOk)) · re-run no duplicates \(word(dedupeOk)) · "
                    + "late card to Recent only \(word(lateOk)) · week card \(word(weekOk)) · this phone: \(phone)")
    }
}
