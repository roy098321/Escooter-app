import CorckieCore
import Foundation

/// P6-6 checks (F-31 time to full charge, F-24, F-27), on made-up sessions (nothing real is read or written; the real timer is not touched):
/// u120 the model against the mock (18 % at 19:00), u121 targets and notification times, u122 the charge log chart data.
@MainActor
enum ChargeEtaChecks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    private static let day: Int64 = 86_400_000
    private static var midnight: Int64 { 1_790_000_000_000 - (1_790_000_000_000 % day) }
    private static var at1900: Int64 { midnight + 19 * 3_600_000 }
    private static func clock(_ ms: Int64) -> String { ChargeText.clock(ms, utcOffsetMin: 0) }
    private static func session(_ target: ChargeTarget = .none) -> ChargeSession {
        ChargeSession(id: "check", startPct: 18, startMs: at1900, target: target, pctPerKm: 2.3, usualNeedPct: 20, usualName: "Work", scooterName: "G2")
    }

    static func run() {
        runModel()
        runTargets()
        runLog()
    }

    // MARK: u120

    private static func runModel() {
        let expect = Expect()
        let s = session()
        expect(ChargeModel.ratePctPerHour == 13.6, "the measured 13.6 %/h")
        expect(clock(ChargeModel.timeMs(toPct: 80, s)) == "23:34", "18 % at 19:00: 80 % \u{2248} \(clock(ChargeModel.timeMs(toPct: 80, s)))")
        expect(clock(ChargeModel.fullMs(s)) == "01:02", "full \u{2248} \(clock(ChargeModel.fullMs(s))) (the honest 100 %, no margin)")
        expect(clock(ChargeModel.notifyFullMs(s)) == "01:24", "the full notification at 100 % + 5 % \u{2248} \(clock(ChargeModel.notifyFullMs(s)))")
        expect(abs(ChargeModel.pct(s, atMs: at1900 + 3_600_000) - 31.6) < 0.01, "one hour later \u{2248} 31.6 %")
        expect(ChargeModel.pct(s, atMs: at1900 + 20 * 3_600_000) == 100 && ChargeModel.pct(s, atMs: at1900 - 60_000) == 18, "never above 100, never below the start")
        expect(ChargeText.duration(minutes: 125) == "2 h 05 min", "2 h 05 min")
        CheckResults.shared.set("u120", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u121

    private static func runTargets() {
        let expect = Expect()
        let km = session(.km(10))
        expect(ChargeModel.pctForKm(10, pctPerKm: 2.3) == 31, "10 km at 2.3 %/km +10 % + 5 % reserve, rounded up = 31 %")
        expect(clock(ChargeModel.targetMs(km) ?? 0) == "19:57", "10 km \u{2248} 19:57")
        expect(ChargeModel.pctForKm(10, pctPerKm: nil) == nil, "no %/km, no km target")
        let ready = ChargeModel.nextOccurrence(minuteOfDay: 450, afterMs: at1900, utcOffsetMin: 0)
        let rb = session(.readyBy(atMs: ready))
        expect(ChargeText.readyByLine(rb, atMs: ready, utcOffsetMin: 0) == "\u{2248} 100 % by then, enough for Work and back", "ready by 07:30: \u{2248} 100 %, enough for Work and back")
        let t22 = midnight + 22 * 3_600_000
        expect(ChargeText.readyByLine(rb, atMs: t22, utcOffsetMin: 0) == "\u{2248} 59 % by 22:00, enough for Work and back", "ready by 22:00: \u{2248} 59 %")
        let plan = ChargeNotifications.plan(session(.km(10)), nowMs: at1900, utcOffsetMin: 0)
        expect(plan.map(\.id) == ["charge.target", "charge.full"] || plan.map(\.id) == ["charge.full", "charge.target"], "two notifications: the target and full")
        expect(plan.first { $0.id == "charge.full" }.map { clock($0.atMs) == "01:24" && $0.title == "G2 is full." && $0.body == "Unplug when convenient." } == true, "full: G2 is full. Unplug when convenient. at 01:24")
        expect(plan.first { $0.id == "charge.target" }?.title == "G2 has enough for 10 km (\u{2248} 31 %).", "target: G2 has enough for 10 km (\u{2248} 31 %).")
        expect(ChargeNotifications.plan(session(.pct(80)), nowMs: at1900 + 5 * 3_600_000, utcOffsetMin: 0).map(\.id) == ["charge.full"], "a passed time is not scheduled again")
        expect(ChargeNotifications.plan(rb, nowMs: at1900, utcOffsetMin: 0).map(\.id) == ["charge.full"], "full by the ready time: only the full note")
        CheckResults.shared.set("u121", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u122

    private static func runLog() {
        let expect = Expect()
        let s = session()
        let est = ChargeLogEntry.finish(s, atMs: at1900 + 3_600_000, realPct: nil)
        let real = ChargeLogEntry.finish(s, atMs: at1900 + 3_600_000, realPct: 35)
        expect(!est.measured && abs(est.endPct - 31.6) < 0.01, "Unplugged keeps the estimate (\u{2248} 31.6 %), logged as estimated")
        expect(real.measured && real.endPct == 35, "the real % on connect is logged as measured")
        let rows = ChargeLogChart.rows(entries: [est, real.self], detected: [])
        expect(rows.count == 2 && Set(rows.map(\.solid)) == [true, false], "solid bar for measured, lighter for \u{2248}")
        let seg = ChargeLogChart.segments([ChargeReading(ms: 0, pct: 80), ChargeReading(ms: 3_600_000, pct: 70), ChargeReading(ms: 12 * 3_600_000, pct: 30)])
        expect(seg.map(\.dashed) == [false, true], "a long gap between readings is dashed, no invented curve")
        let m = ChargeLogEntry(id: "m", startMs: 0, endMs: 139 * 60_000, startPct: 33, endPct: 65, measured: true)
        expect(ChargeLogChart.detail(ChargeLogChart.rows(entries: [m], detected: [])[0]) == "+32 % \u{00B7} 2 h 19", "+32 % \u{00B7} 2 h 19")
        CheckResults.shared.set("u122", expect.ok ? .pass : .fail, expect.line)
    }
}
