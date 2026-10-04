import CorckieCore
import CorckieSim
import Foundation

/// u9 (M1-03): ride start through the real ride engine on the fake scooter: the three autostart traps
/// (walk → trimmed away or cancelled, wheel spin → cancelled within 20 s, kick-start → confirmed by the motor
/// current), Start ride skips stage 2, Not riding cancels silently, nothing starts without the scooter.
enum RideEngineCheck {
    static func runStart() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        func scenario(_ id: String) -> SimStream? { SyntheticScenario.all.first { $0.id == id }?.build() }

        if let walk = scenario("TRAP-WALK") {
            let r = EngineRunner.run(walk, tailS: 30)
            let ride = r.engine.ride ?? r.ends.first?.ride
            let trimmedAway = ride.map { $0.trimStartT == nil && $0.distanceAfterTrimM == 0 } ?? false
            expect(!r.cancelled.isEmpty || trimmedAway, "walk: cancelled or trimmed away (no riding distance)")
        } else { expect(false, "TRAP-WALK scenario missing") }

        if let spin = scenario("TRAP-SPIN") {
            let r = EngineRunner.run(spin, tailS: 30)
            var wait: Double?
            if let s = r.started.first, let c = r.cancelled.first { wait = c.at - s.at }
            expect(r.cancelled.first?.reason == .gpsStill && (wait ?? 99) <= T.t14CancelGpsStillS + 1,
                   "wheel spin: cancelled silently after \(wait.map { String(format: "%.0f", $0) } ?? "–") s (≤ 20)")
        } else { expect(false, "TRAP-SPIN scenario missing") }

        if let kick = scenario("TRAP-KICK") {
            let r = EngineRunner.run(kick, tailS: 30)
            expect(r.cancelled.isEmpty && r.confirmed.first?.by == .current,
                   "kick-start: confirmed by \(r.confirmed.first?.by.rawValue ?? "nothing")")
        } else { expect(false, "TRAP-KICK scenario missing") }

        var e = RideEngine()
        expect(e.handle(.startPressed, at: 0).isEmpty, "no scooter: Start ride does nothing")
        e.handle(.connected, at: 1)
        let manual = e.handle(.startPressed, at: 2)
        expect(manual.contains(.rideConfirmed(seq: 1, at: 2, by: .manual)) && e.phase == .riding,
               "Start ride by hand skips stage 2")
        expect(e.handle(.notRidingPressed, at: 5) == [.rideCancelled(seq: 1, at: 5, reason: .notRiding)] && e.ride == nil,
               "Not riding: cancelled silently")

        CheckResults.shared.set("u9", ok ? .pass : .fail, notes.joined(separator: " · "))
    }

    /// u10 (M1-04): stops and ride end on the fake scooter: end A (dropped while standing, GPS still), A2 (0x80, at
    /// once), auto-off without 0x80, standstill 10 min, battery empty → push 1 km (walking stretch + "battery ran out"),
    /// Same ride after a switch-off at a light, and an app relaunch mid-ride (resumed, or recovered after > 2 min).
    static func runEnd() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        func run(_ id: String, answer: Bool? = nil, relaunchAt: Double? = nil, gap: Double = 3) -> EngineRunner.Result? {
            guard let s = SyntheticScenario.all.first(where: { $0.id == id })?.build() else {
                expect(false, "\(id) scenario missing")
                return nil
            }
            return EngineRunner.run(s, relaunchAt: relaunchAt, relaunchGapS: gap, answerSameRide: answer)
        }
        func f0(_ v: Double) -> String { String(format: "%.0f", v) }

        if let r = run("END-A"), let e = r.ends.first {
            expect(e.reason == .disconnected && abs(e.endT - 135) <= 2,
                   "dropped while standing: ends by A after 30 s (\(f0(e.decidedAtT - 155)) s), end time = last movement")
        } else { expect(false, "END-A: no end") }
        if let r = run("OFF-0x80"), let e = r.ends.first {
            expect(e.reason == .scooterOff && e.decidedAtT - 150 <= 1, "0x80: ends at once (scooter switched off)")
        } else { expect(false, "OFF-0x80: no end") }
        if let r = run("AUTO-OFF"), let e = r.ends.first {
            expect(e.reason == .disconnected && abs(e.endT - 135) <= 2, "auto-off after 5 min (no 0x80): ends, end time = last movement")
        } else { expect(false, "AUTO-OFF: no end") }
        if let r = run("STANDSTILL-10"), let e = r.ends.first {
            expect(e.reason == .standstill, "standing 10 min with the scooter on: ends by standstill")
        } else { expect(false, "STANDSTILL-10: no end") }
        if let r = run("PUSH-1KM"), let e = r.ends.first, let w = e.ride.walks.first {
            expect(abs(w.distanceM - 1_000) <= 150 && e.batteryRanOutPct == 3,
                   "push 1 km: \(String(format: "%.1f", w.distanceM / 1000)) km walked · battery ran out at \(e.batteryRanOutPct.map(String.init) ?? "–")%")
            let m = e.metrics(r.samples[e.ride.seq] ?? [])
            let avg = (m.avgMovingMps ?? 0) * 3.6
            expect((20...27).contains(avg), "walking left out of avg. speed while moving (\(f0(avg)) km/h)")
        } else { expect(false, "PUSH-1KM: no walking stretch") }
        if let r = run("SAME-RIDE", answer: true) {
            let merged = r.events.contains { $0.event == .rideMerged(seq: 2, intoSeq: 1) }
            expect(r.sameRideOffers.count == 1 && merged, "off at a light, on again: \"Same ride?\" offered, Yes joins the pieces")
        }
        if let a = run("END-A"), let b = run("END-A", relaunchAt: 60) {
            expect(b.recoveries == [.resume] && b.ends.first?.reason == a.ends.first?.reason && b.started.count == 1,
                   "app relaunched mid-ride: the same ride goes on")
        }
        if let r = run("END-A", relaunchAt: 60, gap: 300), case let .endRecovered(e)? = r.recoveries.first {
            expect(e.status == "recovered" && 60 - e.endT <= 5, "app gone > 2 min: ride recovered at its last sample (\(f0(60 - e.endT)) s lost)")
        } else { expect(false, "long relaunch: not recovered") }

        CheckResults.shared.set("u10", ok ? .pass : .fail, notes.joined(separator: " · "))
    }
}
