import CorckieCore
import Foundation
import GRDB

/// P6-4 chunk 3b checks (F-21 insights), on made-up rides and temporary databases (nothing real is read or written):
/// u100 the speed sweet spot maths, u101 departure time and battery-use creep, u102 today's wind (honest number, +10 % on the action),
/// u103 the certainty gate (shown at High, hidden at Low), at most 3 cards, and the old insight rows cleared.
@MainActor
enum P64C3bChecks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    typealias S = InsightSamplesF21

    static func run() {
        runSweetSpot()
        runDepartureAndCreep()
        runWind()
        runGate()
    }

    // MARK: u100

    private static func runSweetSpot() {
        let expect = Expect()
        let card = SweetSpotInsight.make(rides: S.sweetRides(9), context: S.sweetContext()).shown
        let words = card?.headline.split(separator: " ") ?? []
        let best = words.count >= 2 ? Int(words[words.count - 2]) ?? 0 : 0
        expect(card != nil && (26...30).contains(best), "9 made-up rides with the lowest use at 28 km/h: \(card?.headline ?? "no card")")
        expect(card?.chart?.band?.contains(28) == true, "the interval holds 28 km/h (\(card?.certainty.interval ?? "-"))")
        expect(card?.certainty.level == .high, "High certainty on 63 steady stretches")
        let base = card?.whatIf.first { $0.isBaseline }?.items.first?.text ?? ""
        expect(base.hasPrefix("~33 km range"), "the baseline range is the honest (100 \u{2212} 5) \u{00F7} 2.9 %/km, no margin: \(base)")
        let faster = card?.whatIf.filter { $0.note.hasPrefix("(+") } ?? []
        expect(!faster.isEmpty && faster.allSatisfy { $0.items.first?.tone == .worse },
               "cruising faster than usual costs range: \(faster.map { $0.items.first?.text ?? "" }.joined(separator: ", "))")
        var cuts = SweetSpotInsight.Cuts()
        let climb = (0..<90).map { SpeedSample(tS: Double($0), speedKmh: 28, powerW: 400, altM: 10 + 0.4 * Double($0)) }
        expect(SweetSpotInsight.stretches(rideId: "c", samples: climb, cuts: &cuts).isEmpty && cuts.climbs == 1, "a 5 % climb is left out")
        expect(SweetSpotInsight.make(rides: S.sweetRides(9, bend: 0, noise: 0.05), context: S.sweetContext()).shown == nil, "a flat curve shows nothing")
        CheckResults.shared.set("u100", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u101

    private static func runDepartureAndCreep() {
        let expect = Expect()
        let dep = DepartureInsight.make(rides: S.departureRides(), destination: "Work", utcOffsetMin: 180).shown
        expect(dep?.value == "\u{2212}6" && dep?.headline.hasSuffix("beats 8:10") == true, "leaving ~7:30 is 6 min quicker than 8:10: \(dep?.headline ?? "no card")")
        expect(dep?.whatIf.first { $0.note == "(\u{2212}30 min)" }?.items.first?.tone == .better, "leave 30 min earlier: quicker")
        expect(DepartureInsight.make(rides: S.departureRides(gainMin: 1), destination: nil, utcOffsetMin: 180).shown == nil, "1 min is not worth a card")
        let creep = CreepInsight.make(rides: S.creepRides(), reservePct: 5, utcOffsetMin: 180).shown
        expect(creep?.value == "+9" && creep?.action == "Check tyre pressure (usually the cause)", "9 % more per km on the same routes: \(creep?.headline ?? "no card")")
        expect(CreepInsight.make(rides: S.creepRides(increase: 0), reservePct: 5, utcOffsetMin: 180).shown == nil, "no increase, no card")
        expect(CreepInsight.make(rides: S.creepRides(increase: -0.1), reservePct: 5, utcOffsetMin: 180).shown == nil, "less battery is no maintenance")
        CheckResults.shared.set("u101", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u102

    private static func runWind() {
        let expect = Expect()
        let card = WindTodayInsight.make(history: S.windHistory(), today: S.windToday(), utcOffsetMin: 180).shown
        expect(card?.value == "+9", "26 km/h headwind on a 12 km trip: +9 % battery, shown honestly (\(card?.value ?? "none"))")
        expect(card?.action == "Leave Work with at least 30 %", "the action adds the reserve and the 10 % margin (P-1): \(card?.action ?? "none")")
        expect(card?.kind == .today, "a TODAY card (Home only)")
        expect(WindTodayInsight.make(history: S.windHistory(), today: S.windToday(headwindKmh: 8), utcOffsetMin: 180).card == nil, "light wind: no card")
        expect(WindTodayInsight.make(history: S.windHistory(5), today: S.windToday(), utcOffsetMin: 180).card == nil, "5 rides: still learning")
        CheckResults.shared.set("u102", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u103

    private static func runGate() {
        let expect = Expect()
        expect(InsightGate.level(n: 15, mediumN: 8, highN: 15, t: 3.2) == .high && CertaintyLevel.high.shown, "enough rides and |t| \u{2265} 3: High, shown")
        expect(InsightGate.level(n: 8, mediumN: 8, highN: 15, t: 2.1) == .medium && CertaintyLevel.medium.shown, "|t| \u{2265} 2: Medium, shown")
        expect(InsightGate.level(n: 30, mediumN: 8, highN: 15, t: 1.5) == .low && !CertaintyLevel.low.shown, "an interval that includes no difference: Low, hidden")
        expect(InsightGate.level(n: 5, mediumN: 8, highN: 15, t: 9) == .low, "too few rides: Low, hidden")
        let board = InsightBoard.make(S.outcomes())
        expect(board.cards.count == 3 && !board.cards.contains { $0.kind == .today }, "Stats shows at most 3 cards and never the TODAY one")
        expect(board.cards.allSatisfy { $0.headlineWords <= 8 }, "every headline is 8 words or fewer")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try temp.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO insight (id, type, text, createdAt) VALUES ('a', 'heatPeak', 'Peak 93', 1), ('b', 'progress.firstRide', 'Ride the same trip', 1),
                      ('c', 'q4After', 'kept', 1)
                    """)
            }
            let removed = try InsightQueries(temp).retireOld()
            let left = try InsightQueries(temp).all().map(\.type)
            expect(removed == 2 && left == [.q4After], "old Peak and hint rows are cleared, the rest stays (\(removed) removed)")
            let empty = InsightBoardLoader.board(temp)
            expect(empty.cards.isEmpty && empty.learning.count == 3, "no rides: no cards, three topics still learning")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u103", expect.ok ? .pass : .fail, expect.line)
    }
}
