import CorckieCore
import CorckieSim
import Foundation

/// Batch 101.251026.00 chunk A checks ("never lose a ride"), on made-up input only (nothing real is read or written):
/// u130 the battery % flip filter and its per-scooter auto-detect (B56, B56b),
/// u131 a ride the phone took over is kept with its GPS distance and top speed, "Recorded by phone", restore list (B57),
/// u132 a ride's start / end battery are settled readings: the boot 100 % never reaches them; "went up" shows the start once (B54).
@MainActor
enum B101Checks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    static func run() {
        runFlipFilter()
        runPhoneRide()
        runSettledBattery()
    }

    // MARK: u132

    private static func runSettledBattery() {
        let expect = Expect()
        var p = ScooterPipeline()
        p.handle(TimedScooterEvent(t: 0, event: .connected))
        var seen: [Int?] = []
        for (i, pct) in [100, 100, 100, 99, 99, 99, 99].enumerated() {
            var v = PacketEncoder.Values()
            v.batteryPct = pct
            p.handle(TimedScooterEvent(t: Double(i) + 0.5, event: .packet(PacketEncoder.packetA(v))))
            seen.append(p.frame?.batteryPct)
        }
        expect(!seen.contains(100) && seen.last == 99, "B54: boot 100, 100, 100 then 99: the frames never carry 100")
        expect(RideSummaryBuilder.build(RideDetailInput(startAt: 0, startRestPct: 99, endRestPct: 100), gaps: [], points: [])
                .mainStats.first { $0.label == "Battery" }?.value == "99%", "a ride that went 99 \u{2192} 100 shows 99% once")
        CheckResults.shared.set("u132", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u131

    private static func runPhoneRide() {
        let expect = Expect()
        expect(PhoneRide.sizeClass(distanceM: 0, gpsM: 1_930, phoneTookOver: true) == .shortHop,
               "B57: 0 m on the frozen odometer but 1.93 km of GPS after the phone took over is kept")
        expect(PhoneRide.sizeClass(distanceM: 0, gpsM: 250, phoneTookOver: true) == .discarded, "under 300 m of GPS is still a discarded piece")
        expect(PhoneRide.distanceM(scooterM: 40, gpsM: 1_930, scooterLost: true) == 1_930
               && PhoneRide.topSpeedKmh(scooterKmh: 0, gpsKmh: 27, scooterLost: true) == 27, "distance and top speed from the GPS")
        var input = RideDetailInput(startAt: 1_790_000_000_000, kind: "shortHop", distanceM: 1_930, totalS: 360)
        input.recordedByPhone = true
        let m = RideSummaryBuilder.build(input, gaps: [], points: [])
        expect(m.subtitle.contains("Recorded by phone") && m.notes.contains { $0.kind == .phone }, "the summary says Recorded by phone with a note")
        let now: Int64 = 1_790_000_000_000
        let ids = PhoneRide.restoreCandidates([("a", now - 86_400_000, "discarded", false, true), ("b", now - 40 * 86_400_000, "discarded", false, true)], nowMs: now)
        expect(ids == ["a"], "Restore discarded ride offers the last 30 days only")
        CheckResults.shared.set("u131", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u130

    private static func runFlipFilter() {
        let expect = Expect()
        var flip = BatteryFilter()
        var shown: [Int] = []
        for i in 0..<80 { shown.append(flip.reading(i % 2 == 0 ? 100 : 99, at: Double(i))) }
        expect(flip.detector.filterOn && Set(shown.suffix(40)) == [99], "B56: 100, 99, 100, 99 \u{2026} turns the filter on and shows 99 (\(flip.detector.line))")
        var clean = BatteryFilter()
        let raw = (0..<300).map { 90 - $0 / 10 }
        let out = raw.enumerated().map { clean.reading($0.element, at: Double($0.offset)) }
        expect(!clean.detector.filterOn && out == raw, "B56b: a scooter that doesn't flip is untouched")
        var up = BatteryFilter(detector: flip.detector)
        up.newConnection()
        _ = up.reading(80, at: 0)
        let early = up.reading(81, at: 1)
        let held = up.reading(81, at: 61)
        let jump = up.reading(83, at: 62)
        expect(early == 80 && held == 81 && jump == 83, "+1 shows only after 60 s, +2 at once")
        let stored = BatteryFlipDetector.parse(flip.detector.json)
        expect(stored.filterOn && stored.changes == flip.detector.changes, "the flip history is kept per scooter")
        CheckResults.shared.set("u130", expect.ok ? .pass : .fail, expect.line)
    }
}
