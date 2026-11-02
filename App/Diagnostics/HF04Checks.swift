import CorckieCore
import Foundation

/// Hotfix 102.011126.02 checks (B71), on made-up rides of a made-up route only (`V09Lab`; nothing real is read or written).
/// u191 stored rows ~5 s apart count: the route history, the live battery and the sanity guard,
/// u192 the voice: arrival below the battery now halfway, no line with under 5 points left, the replay fails the old behaviour,
/// u193 (B72) the unplugged estimate ends on the next real reading and the Scooter tab shows Home's reading (made-up numbers only).
@MainActor
enum HF04Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runHistory()
        runVoice()
        runUnplugged()
    }

    private static let wh = V09Lab.storedWhPerPct

    private static func follower(_ h: RouteHistory?) -> RouteFollower? {
        guard let h else { return nil }
        return V09Lab.follower(todayS: h.usualTotalS ?? 2_060, history: h)
    }

    // MARK: u191

    private static func runHistory() {
        let expect = Expect()
        let ride = V09Lab.storedRide()
        let gaps = zip(ride, ride.dropFirst()).map { $0.1.t - $0.0.t }
        expect((gaps.max() ?? 99) <= SagProofBattery.maxStepS,
               "made-up ride 85 \u{2192} 48 %, rows \(String(format: "%.1f", gaps.min() ?? 0))\u{2013}\(String(format: "%.1f", gaps.max() ?? 0)) s apart, gap limit \(Int(SagProofBattery.maxStepS)) s")
        if let f = V09Lab.follower() {
            let used = RouteRideProfile.make(samples: ride, route: f, whPerPct: wh)?.usedPct.last ?? 0
            expect(abs(used - 37) <= 3, "route history: \(String(format: "%.1f", used)) % used (battery fell 37)")
            let old = RouteRideProfile.makeChecked(samples: ride, route: f, whPerPct: wh, maxStepS: 5)
            expect(old.profile == nil && old.leftOut != nil, "the old 5 s limit: " + (old.leftOut ?? "kept (wrong)"))
        } else {
            expect(false, "made-up route")
        }
        var b = SagProofBattery()
        for s in ride { b.update(t: s.t, livePct: s.batteryPct, powerW: s.powerW, currentA: s.currentA, speedKmh: s.speedKmh, whPerPct: wh) }
        expect(abs(b.usedWh - 340) <= 10, "live battery counts the same rows: \(Int(b.usedWh.rounded())) Wh")
        expect.report("u191")
    }

    // MARK: u192

    private static func runVoice() {
        let expect = Expect()
        if let f = follower(V09Lab.storedHistory()) {
            let r = V09Replay.run(samples: V09Lab.storedRide(), route: f, whPerPct: wh)
            let level = r.midRoute?.levelPct ?? 0, arrive = r.midRoute?.arrivalPct ?? 0
            expect(r.passed && arrive < level - 10,
                   "halfway: arrival about \(Int(arrive.rounded())) %, battery now \(Int(level.rounded())) %" + (r.passed ? "" : " \u{00B7} " + r.problems.joined(separator: ", ")))
            let heavy = V09Replay.run(samples: V09Lab.storedRide(extra: { $0 >= 2 && $0 < 5 ? 2 : 1 }), route: f, whPerPct: wh)
            let lines = heavy.said.filter { ["drop", "low"].contains($0.kind) }
            expect(heavy.passed && !lines.isEmpty, "a heavy stretch: " + lines.map(\.line).joined(separator: " ") + (heavy.passed ? "" : " \u{00B7} " + heavy.problems.joined(separator: ", ")))
        } else {
            expect(false, "made-up history")
        }
        if let good = V09Lab.storedHistory()?.rides.first {
            let broken = RouteRideProfile(alongKm: good.alongKm, elapsedS: good.elapsedS, usedPct: good.usedPct.map { _ in 0 })
            if let f = follower(RouteHistory(rides: [broken, broken, broken], routeKm: V09Lab.km)) {
                let r = V09Replay.run(samples: V09Lab.storedRide(), route: f, whPerPct: wh)
                let said = r.said.filter { ["drop", "low", "back"].contains($0.kind) }
                expect(said.isEmpty, "under 5 points left to use: no arrival line")
                expect(!r.passed, "the old behaviour fails the replay: " + r.problems.joined(separator: ", "))
            }
        }
        expect.report("u192")
    }

    // MARK: u193 (B72)

    private static func runUnplugged() {
        let expect = Expect()
        let unplug: Int64 = 1_000_000, ride: Int64 = unplug + 2 * 60_000, end: Int64 = unplug + 38 * 60_000
        let a = UnpluggedEstimate.settle(unpluggedMs: unplug, connectedPct: 85, riding: false, rideSince: nil)
        expect(a == .clearAndComplete(85), "unplugged at \u{2248} 84 %, connected with 85 %: the estimate ends, the charge is measured")
        let log = UnpluggedEstimate.complete([ChargeLogEntry(id: "x", startMs: unplug - 3_600_000, endMs: unplug, startPct: 70, endPct: 84,
                                                             measured: false)], realPct: 85)
        expect(log.first?.measured == true && log.first?.endPct == 85, "the charge log entry: 70 \u{2192} 85 %, measured")
        let riding = UnpluggedEstimate.settle(unpluggedMs: unplug, connectedPct: 80, riding: true, rideSince: nil)
        let after = UnpluggedEstimate.settle(unpluggedMs: unplug, connectedPct: nil, riding: false, rideSince: (startMs: ride, startRestPct: 85))
        expect(riding == .keep && after == .clearAndComplete(85), "connected only while riding: ended after the ride with its rested start 85 %")
        let home = LastReading.pick(seen: nil, rideEnd: BatteryReading(pct: 47, ms: end))
        expect(home?.pct == 47 && !UnpluggedEstimate.shows(unpluggedMs: unplug, lastReadingMs: home?.ms),
               "after a ride to 47 %: Home and the Scooter tab both 47 %, no old estimate")
        let waiting = ChargeTimer.shared.unplugged.map { "an unplugged estimate of \(Int($0.pct.rounded())) % is waiting for a reading" }
        expect(true, "this phone: " + (waiting ?? "no unplugged estimate waiting"))
        expect.report("u193")
    }
}
