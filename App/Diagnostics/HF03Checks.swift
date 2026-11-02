import CorckieCore
import Foundation

/// Hotfix 102.011126.01 checks, on made-up rides of a made-up route only (`V09Lab`; nothing real is read or written).
/// u186 H1 arrival battery: a hill sag says nothing, a real drain says one line, the number never goes up (B69),
/// u187 H2 running late: an early red light is not late, really late is said once after the gate, the arrival time is not inflated (B70),
/// u188 H3 the start line, u189 proof: the voice replay's pass rules, the line log and the ride summary's said-vs-real lines.
@MainActor
enum HF03Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runH1()
        runH2()
        runH3()
        runProof()
    }

    private static func replay(_ ride: [RouteHistorySample], place: String? = nil) -> V09Replay.Result? {
        guard let f = V09Lab.follower(history: V09Lab.history()) else { return nil }
        return V09Replay.run(samples: ride, route: f, whPerPct: 8.1, placeName: place)
    }

    private static func battery(_ r: V09Replay.Result?) -> [V09SaidLine] {
        (r?.said ?? []).filter { ["drop", "low", "back"].contains($0.kind) }
    }

    // MARK: u186

    private static func runH1() {
        let expect = Expect()
        let hill = V09Lab.ride(sagKm: 4)
        var b = SagProofBattery()
        var worst = 0.0
        for s in hill {
            let l = b.update(t: s.t, livePct: s.batteryPct, powerW: s.powerW, currentA: s.currentA, speedKmh: s.speedKmh, whPerPct: 8.1) ?? 0
            let km = V09Lab.km(of: s)
            worst = max(worst, abs(l - (90 - 2 * km)))
        }
        expect(worst < 1.5, "sag-proof level stays with the energy on the hill (off by at most \(String(format: "%.1f", worst)))")
        let h = battery(replay(hill))
        expect(h.isEmpty, "hill sag (8 points for 40 s): " + (h.isEmpty ? "nothing said" : h.map(\.line).joined(separator: " ")))
        let drain = battery(replay(V09Lab.ride(pctPerKm: { $0 < 3 ? 2 : 3.2 })))
        expect(drain.count == 1, "a real drain: one line (" + drain.map(\.line).joined(separator: " ") + ")")
        let mixed = battery(replay(V09Lab.ride(pctPerKm: { km in km < 3 ? 2 : km < 5 ? 5 : km < 7 ? 0.5 : 5 }))).compactMap(\.value)
        expect(zip(mixed, mixed.dropFirst()).allSatisfy { $0.1 < $0.0 } && mixed.count <= 2, "heavy, easy, heavy: never a higher number (\(mixed))")
        expect.report("u186")
    }

    // MARK: u187

    private static func runH2() {
        let expect = Expect()
        let red = replay(V09Lab.ride(stopAtKm: 1))
        expect(!(red?.said ?? []).contains { $0.kind == "late" }, "an early 60 s red light: no late line")
        let slow = (replay(V09Lab.ride(slowFromKm: 2))?.said ?? []).filter { $0.kind == "late" }
        expect(slow.count == 1 && (slow.first?.numbers.alongKm ?? 0) >= 10.0 / 3,
               "crawling from km 2: " + (slow.first.map { "\($0.line) at km \(String(format: "%.1f", $0.numbers.alongKm ?? 0))" } ?? "nothing"))
        if var f = V09Lab.follower() {
            _ = f.update(position: V09Lab.point(0), gpsFresh: true, rideDistanceM: 0, elapsedS: 0)
            let s = f.update(position: V09Lab.point(2_000), gpsFresh: true, rideDistanceM: 2_000, elapsedS: 288 + 120)
            expect(abs(s.remainingS - 1_440 * 0.8) < 15, "2 min lost early: the time still to ride stays the rest of today (\(Int(s.remainingS)) s)")
        }
        expect.report("u187")
    }

    // MARK: u188

    private static func runH3() {
        let expect = Expect()
        let said = replay(V09Lab.ride(), place: "Uni")?.said ?? []
        let start = said.filter { $0.kind == "start" }
        expect(start.count == 1, "said once")
        let line = start.first?.line ?? ""
        expect(line.hasPrefix("Riding to Uni, arriving at ") && line.hasSuffix(", battery at ninety percent."), "the line: " + line)
        expect(said.first?.kind == "start", "the first thing said")
        expect(true, "voice energy updates are " + (V09Settings.isOn ? "on" : "off") + " in Settings (the start line needs them on)")
        expect.report("u188")
    }

    // MARK: u189

    private static func runProof() {
        let expect = Expect()
        let rides = [V09Lab.ride(), V09Lab.ride(sagKm: 4), V09Lab.ride(pctPerKm: { $0 < 3 ? 2 : 3.2 }), V09Lab.ride(stopAtKm: 1)]
        let results = rides.compactMap { replay($0) }
        expect(results.count == 4 && results.allSatisfy(\.passed),
               "voice replay pass rules on 4 made-up rides: " + results.map { $0.passed ? "pass" : $0.problems.joined(separator: ", ") }.joined(separator: " / "))
        let bad = V09Replay.verdict(V09Replay.Result(said: [V09SaidLine(.sharpDrop(pct: 40), numbers: V09Numbers()),
                                                            V09SaidLine(.sharpDrop(pct: 45), numbers: V09Numbers())],
                                                     realArrivalPct: 41, realArrivalS: nil, problems: []), routeKm: 10)
        expect(!bad.passed, "a higher number after a lower one fails: " + bad.problems.joined(separator: ", "))
        var n = V09Numbers()
        n.t = 1_000
        n.arrivalPct = 42
        let line = V09SaidLine(.sharpDrop(pct: 40), numbers: n)
        let back = (try? JSONEncoder().encode([line])).flatMap { try? JSONDecoder().decode([V09SaidLine].self, from: $0) }
        expect(back == [line], "the line log keeps the line with its numbers")
        let compare = V09SaidCompare.lines([line], realArrivalPct: 43, realArrivalS: nil, utcOffsetMin: 0)
        expect(compare.first?.contains("real 43% (3 off)") == true, "ride summary: " + (compare.first ?? "nothing"))
        if let db = AppModel.shared.database { expect(true, "this phone has \(V09LineLog.all(db).count) logged voice lines") }
        expect.report("u189")
    }
}
