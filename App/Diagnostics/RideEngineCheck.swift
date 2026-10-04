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
}
