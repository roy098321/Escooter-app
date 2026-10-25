import CorckieCore
import CorckieSim
import Foundation

/// Batch 101.251026.00 chunk A checks ("never lose a ride"), on made-up input only (nothing real is read or written):
/// u130 the battery % flip filter and its per-scooter auto-detect (B56, B56b),
/// u131 a ride the phone took over is kept with its GPS distance and top speed, "Recorded by phone", restore list (B57),
/// u132 a ride's start / end battery are settled readings: the boot 100 % never reaches them; "went up" shows the start once (B54),
/// u133 a ride ends at its last movement and a stop inside it counts in its Time (F-38),
/// u134 the ride starts at the first real riding movement, back-dated; pushing, standing and a lifted wheel do not start it (B62).
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
        runEndTime()
        runRidingStart()
    }

    /// Made-up frames and fixes one a second: `kmh` on the wheel with `amps`; the phone moves too unless `lifted`
    private struct Feed {
        var e = RideEngine()
        var events: [RideEngineEvent] = []
        var t = 0.0
        var odo = 100.0
        var north = 0.0

        init() {
            e.handle(.connected, at: 0)
            events += e.handle(.frame(ScooterFrame(t: 0)), at: 0)
        }

        mutating func go(for seconds: Double, kmh: Double, amps: Double, lifted: Bool = false) {
            let end = t + seconds
            while t < end {
                t += 1
                if !lifted { odo += kmh / 3600; north += kmh / 3.6 }
                var f = ScooterFrame(t: t)
                f.speedKmh = kmh
                f.currentA = amps
                f.batteryPct = 80
                f.odometerKm = odo
                f.voltage = 50
                events += e.handle(.frame(f), at: t)
                events += e.handle(.fix(PhoneFix(t: t, lat: 10 + north / 111_320, lon: -30, hAccM: 5, speedMps: lifted ? 0 : kmh / 3.6)), at: t)
            }
        }

        var end: RideEnd? { events.compactMap { if case .rideEnded(let x) = $0 { return x } else { return nil } }.first }
        var ridingAt: Double? { events.compactMap { if case let .ridingStarted(_, at) = $0 { return at } else { return nil } }.first }
    }

    // MARK: u133

    private static func runEndTime() {
        let expect = Expect()
        var f = Feed()
        f.go(for: 300, kmh: 20, amps: 8)
        f.go(for: 120, kmh: 0, amps: 0)
        f.go(for: 280, kmh: 20, amps: 8)
        f.go(for: 700, kmh: 0, amps: 0)
        let end = f.end
        expect(end?.reason == .standstill && abs((end?.endT ?? 0) - 700) <= 1.5, "F-38: standing 10 min after the last movement ends the ride at the last movement (\(Int(end?.endT ?? 0)) s)")
        expect(end?.ride.stops.count == 1, "the 2 min stop inside the ride is kept")
        let time = RideEndTime.timeS(firstMoveS: end?.ride.firstMoveT, lastMoveS: end?.endT) ?? 0
        expect(abs(time - 699) <= 2, "Time is start to last movement with the stop in it (\(Int(time)) s)")
        CheckResults.shared.set("u133", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u134

    private static func runRidingStart() {
        let expect = Expect()
        var a = Feed()
        a.go(for: 60, kmh: 4, amps: 0)
        let before = a.ridingAt
        a.go(for: 300, kmh: 20, amps: 8)
        expect(before == nil && a.ridingAt == 61, "B62: pushing it out for a minute is not riding; the ride starts at the first riding second (\(a.ridingAt.map { String(Int($0)) } ?? "none"))")
        var b = Feed()
        b.go(for: 90, kmh: 5, amps: 0)
        b.go(for: 700, kmh: 0, amps: 0)
        expect(b.end == nil, "only pushing at walking pace: nothing is saved")
        var c = Feed()
        c.go(for: 30, kmh: 25, amps: 6, lifted: true)
        expect(c.ridingAt == nil, "a lifted wheel spinning while the phone stays still is not riding")
        expect(RideStartRule.ridingKmh == 8 && RideStartRule.ridingHoldS == 3, "the thresholds: 8 km/h, 3 s in a row")
        CheckResults.shared.set("u134", expect.ok ? .pass : .fail, expect.line)
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
