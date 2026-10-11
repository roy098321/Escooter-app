import CorckieCore
import Foundation
import GRDB

/// u42 (M6-01, Q23): the made-up choice-point rides (`ChoiceSeed`) in temporary databases: the tables are filled, the fastest
/// combination is the never-ridden park + left mix, the Follow path stays on ridden stretches, an option seen twice waits ("2 of 3"),
/// Q3 gets a verdict; ends with this phone's choice points.
enum FastestCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        do {
            let a = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { a.discardTemporary() }
            let ids = try ChoiceSeed.route(a)
            let now = ChoiceSamples.t0 + 20 * ChoiceSamples.day
            let counts = try ChoiceQueries(a).counts(routeId: ChoiceSamples.routeId)
            let tablesOk = counts.points == 2 && counts.options == 4 && counts.rideOptions == 18

            let answer = FastestService.answer(a, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: [])
            var comboOk = false
            var pathOk = false
            var timeText = "-"
            if let answer, case .combination(let c) = answer.state {
                comboOk = c.ways.count == 2 && c.ways.allSatisfy { !$0.isReference } && c.savingS >= 66
                timeText = FastestCard.clock(c.timeS)
                let ridden = try ChoiceQueries(a).rides(routeId: ChoiceSamples.routeId, limit: 40).map { r in r.fixes.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
                pathOk = c.path.count > 10 && c.path.allSatisfy { p in (ridden.map { Geo.distanceToPathM(p, $0) }.min() ?? .infinity) < 30 }
            }
            // Follow: the combination's path and time reach the live follower
            let follow = RouteFollowLoader.follower(routeId: ChoiceSamples.routeId, database: a, nowMs: now, combination: true)
            let followOk = follow.map { abs($0.todayS - (answer?.combo?.timeS ?? -1)) < 1 } ?? false

            // gate: "left" only twice → waits, the usual way is kept there
            let b = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { b.discardTemporary() }
            let few = Array(repeating: ChoiceSamples.Spec(.usual, left: false), count: 3) + Array(repeating: ChoiceSamples.Spec(.park, left: false), count: 3)
                + Array(repeating: ChoiceSamples.Spec(.usual, left: true), count: 2)
            try ChoiceSeed.route(b, specs: few)
            let fewAnswer = FastestService.answer(b, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: [])
            let card = fewAnswer.flatMap(FastestCard.make)
            let gateOk = fewAnswer?.waiting.first?.have == 2 && card?.canFollow == false

            // Q3: the park rides get their stretch compared (verdict at the 3rd park ride)
            try InsightRunner.afterRide(a, rideId: ids[5], nowMs: now)
            let q3 = try a.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM insight WHERE type IN ('q3After', 'q3Verdict') AND rideId = ?", arguments: [ids[5]])
            }
            let q3Ok = q3.contains { $0.contains("Verdict") }

            var phone = "no data"
            if let real, let n = try? real.writer.read({ db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM choice_point") ?? 0 }) {
                phone = "\(n) choice points on this phone"
            }
            let all = tablesOk && comboOk && pathOk && followOk && gateOk && q3Ok
            results.set("u42", all ? .pass : .fail,
                        "tables \(word(tablesOk)) (\(counts.points) points, \(counts.options) options, \(counts.rideOptions) times) · fastest = park + left ~\(timeText) \(word(comboOk)) · path on ridden stretches \(word(pathOk)) · Follow \(word(followOk)) · 2 of 3 waits \(word(gateOk)) · Q3 verdict \(word(q3Ok)) · \(phone)")
        } catch {
            results.set("u42", .fail, "The temporary database failed: \(error.localizedDescription)")
        }
    }
}
