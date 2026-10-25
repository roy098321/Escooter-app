import CorckieCore
import CorckieSim
import Foundation
import GRDB

/// Batch 101.251026.00 chunk A checks ("never lose a ride"), on made-up input only (nothing real is read or written):
/// u130 the battery % flip filter and its per-scooter auto-detect (B56, B56b),
/// u131 a ride the phone took over is kept with its GPS distance and top speed, "Recorded by phone", restore list (B57),
/// u132 a ride's start / end battery are settled readings: the boot 100 % never reaches them; "went up" shows the start once (B54),
/// u133 a ride ends at its last movement and a stop inside it counts in its Time (F-38),
/// u134 the ride starts at the first real riding movement, back-dated; pushing, standing and a lifted wheel do not start it (B62),
/// u135 what is a ride: legs to a picked destination merge where the trip ended, Continue, detours out of estimates, trim line, widen (F-39),
/// u136 bad readings are trimmed, never the ride: warm-up after scooter-on, trust returns, plain-words ignored notes (notes 12 + 10).
/// Chunk B ("Where to? + places"): u137 "Riding to Uni, 8 km." and changing the destination at a stop (F-35),
/// u138 a ride is not ended while the scooter is connected and sending, or while GPS shows movement (B63),
/// u139 the Scooter-on notification's destination buttons, Continue first (F-36),
/// u140 the Where to? list never has two rows for one destination: routes link to the place they end in (B61).
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
        runBadReadings()
        runWhatIsARide()
        runDestinationLive()
        runKeptOpen()
        runScooterOnButtons()
        runOneRowPerDestination()
    }

    // MARK: u140

    /// B61: made-up Home + Uni, an unnamed spot inside Home's circle, two saved routes ending at Home: one Where to? row per destination.
    /// This phone's own list is checked too (read only).
    private static func runOneRowPerDestination() {
        let expect = Expect()
        func dupes(_ rows: [WhereToRow]) -> [String] { WhereToDedupe.duplicates(rows.map { WhereToDedupe.Row(key: $0.key, name: $0.name, placeId: $0.placeId) }) }
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try temp.writer.write { d in
                try PlaceRecord(id: "home", name: "Home", lat: 10.0, lon: 20.0, createdAt: 1).insert(d)
                try PlaceRecord(id: "uni", name: "Uni", lat: 10.05, lon: 20.0, createdAt: 2).insert(d)
                try PlaceRecord(id: "spot", name: nil, lat: 10.0008, lon: 20.0, createdAt: 3).insert(d)
            }
            let store = RouteQueries(temp)
            try store.save(route: RouteRecord(id: "r1", fromPlaceId: "uni", toPlaceId: "spot", name: nil, state: "saved", createdAt: 1))
            try store.save(route: RouteRecord(id: "r2", fromPlaceId: nil, toPlaceId: "home", name: nil, state: "saved", createdAt: 2))
            let chips = [WhereToChip(routeId: "r1", label: "Home", detail: "Home"), WhereToChip(routeId: "r2", label: "Home", detail: "Home")]
            let loaded = QuickDialLoader.load(database: temp, routeChips: chips, slots: 3, from: nil)
            expect(dupes(loaded.rows).isEmpty && loaded.rows.filter { $0.name == "Home" }.count == 1,
                   "B61: two routes to Home and Home itself give one Home row (\(loaded.rows.map(\.name).joined(separator: ", ")))")
            expect(loaded.rows.first { $0.name == "Home" }?.placeId == "home", "that row has Home's icon and pin, not a grey letter")
            let linked = try RouteRelink.linkRouteEnds(database: temp)
            let r1To = try store.route(id: "r1")?.toPlaceId
            expect(linked == 1 && r1To == "home", "the route ending inside Home's circle is linked to Home")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        var mine = "no data"
        if let db = AppModel.shared.displayDatabase {
            let rows = QuickDialLoader.load(database: db, routeChips: RouteFollowLoader.chips(database: db, log: false), slots: 3, from: nil).rows
            let d = dupes(rows)
            expect(d.isEmpty, "this phone's Where to? list: \(rows.count) rows, " + (d.isEmpty ? "no duplicates" : d.joined(separator: "; ")))
            mine = "\(rows.count) rows"
        }
        CheckResults.shared.set("u140", expect.ok ? .pass : .fail, expect.line + " \u{00B7} this phone: " + mine)
    }

    // MARK: u139

    /// F-36: the "Scooter on" buttons, "Continue to ..." first (F-39), on made-up places
    private static func runScooterOnButtons() {
        let expect = Expect()
        let places = [ScooterOnActions.Place(key: "r1", name: "Uni", placeId: "uni"), ScooterOnActions.Place(key: "place:home", name: "Home", placeId: "home"),
                      ScooterOnActions.Place(key: "place:gran", name: "Grandma", placeId: "gran")]
        let plain = ScooterOnActions.actions(continueTo: nil, places: places)
        expect(plain.map(\.title) == ["Uni", "Home", "Grandma", "No destination"], "F-36: Uni \u{00B7} Home \u{00B7} Grandma \u{00B7} ? on the notification")
        let resume = ScooterOnActions.actions(continueTo: ScooterOnActions.Place(key: "place:uni", name: "Uni", placeId: "uni"),
                                              continueTitle: "\u{21BB} Continue to Uni", places: places)
        expect(resume.first?.title == "\u{21BB} Continue to Uni" && resume.filter { $0.title.contains("Uni") }.count == 1,
               "after a trip that did not arrive \u{21BB} Continue to Uni is first, Uni not twice")
        expect(ScooterOnActions.choice(actionId: plain[1].id) == .destination("place:home") && ScooterOnActions.choice(actionId: plain[3].id) == .noDestination
               && ScooterOnActions.choice(actionId: resume[0].id) == .continueTrip("place:uni"), "each button maps back to its destination")
        expect(Notifier.destinationActions().last?.title == QuickDialSlot.freeRideName, "this phone's buttons end with No destination")
        CheckResults.shared.set("u139", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u138

    /// B63: connected scooter with untrusted readings, Start pressed, 10 min on GPS with a 60 s stop at a light: the ride stays open
    private static func runKeptOpen() {
        let expect = Expect()
        var e = RideEngine()
        var events: [RideEngineEvent] = []
        var north = 0.0
        func second(_ t: Double, kmh: Double) {
            var f = ScooterFrame(t: t)
            f.speedKmh = 0
            f.voltage = 50
            events += e.handle(.frame(f), at: t)
            north += kmh / 3.6
            events += e.handle(.fix(PhoneFix(t: t, lat: 10 + north / 111_320, lon: -30, hAccM: 5, speedMps: kmh / 3.6)), at: t)
        }
        e.handle(.connected, at: 0)
        second(1, kmh: 0)
        events += e.handle(.formatChanged, at: 2)
        events += e.handle(.startPressed, at: 3)
        for i in 4..<604 { second(Double(i), kmh: (240..<300).contains(i) ? 0 : 20) }
        let ended = events.contains { if case .rideEnded = $0 { return true } else { return false } }
        expect(!ended && e.ride != nil, "B63: untrusted but connected, riding on GPS 10 min with a 60 s stop: the ride stays open")
        expect(e.scooterOnline(at: 603), "packets still arriving: the scooter counts as on")
        CheckResults.shared.set("u138", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u137

    private static func runDestinationLive() {
        let expect = Expect()
        var a = DestinationAnnouncer()
        var said: [Double] = []
        for t in 0..<20 {
            if a.update(riding: true, key: "place:uni", at: Double(t)) { said.append(Double(t)) }
        }
        expect(said == [5], "F-35: said once, 5 s after riding began")
        expect(DestinationLive.ridingLine(name: "Uni", distanceM: 8_040) == "Riding to Uni, 8 km.", "the owner's line: Riding to Uni, 8 km.")
        expect(a.update(riding: true, key: "place:b", at: 120) && DestinationLive.ridingLine(name: "B", distanceM: 2_960) == "Riding to B, 3 km.",
               "a change at a stop is said at once: Riding to B, 3 km.")
        expect(DestinationLive.canChange(speedKmh: 0) && !DestinationLive.canChange(speedKmh: 12) && DestinationLive.stopToChange == "Stop to change",
               "the picker opens only when stopped; moving shows Stop to change")
        var b = DestinationAnnouncer()
        var silent = true
        for t in 0..<20 {
            if b.update(riding: true, key: nil, at: Double(t)) { silent = false }
        }
        expect(silent, "no destination (B62: Where to?) says nothing")
        CheckResults.shared.set("u137", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u135

    private static func runWhatIsARide() {
        let expect = Expect()
        func leg(_ id: String, dest: String?, end: String?) -> TripRules.Leg {
            TripRules.Leg(rideId: id, destinationPlaceId: dest, destinationName: dest == nil ? nil : "Uni", endPlaceId: end,
                          startLat: 10, startLon: 20, endLat: 10, endLon: 20, dayKey: "2026-10-24")
        }
        let first = TripRules.afterRide(leg("a", dest: "uni", end: nil), open: nil)
        expect(first.open.map(TripRules.continueText) == "\u{21BB} Continue to Uni", "F-39: stopped short of Uni: \u{21BB} Continue to Uni is offered")
        expect(TripRules.afterRide(leg("b", dest: nil, end: "uni"), open: first.open).merge == ["a", "b"], "the next leg arrives: one ride to Uni")
        expect(TripRules.afterRide(leg("a", dest: nil, end: nil), open: nil).open == nil, "no destination picked: legs never merge")
        expect(TripRules.picked(placeId: "home", open: first.open) == nil && TripRules.offered(first.open, dayKey: "2026-10-25") == nil,
               "picking another place, or the next day, closes the trip")
        expect(TripRules.isDetour(distanceM: 10_000, othersM: [8_000, 8_100, 8_200]) && !TripRules.isDetour(distanceM: 8_900, othersM: [8_000, 8_100, 8_200]),
               "a 10 km ride where 8.1 km is usual is a detour (kept out of the estimates); 8.9 km is not")
        expect(TripRules.stopTrimLine(stopS: 1_500) == "Includes a 25 min stop, trim it?", "the owner's wording for the stop")
        expect(TripRules.widenRadius(endDistancesM: [230, 260], radiusM: 200, choices: PlaceListBuilder.radiusChoices) == 300,
               "two rides ending just outside a 200 m circle offer 300 m")
        CheckResults.shared.set("u135", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u136

    private static func runBadReadings() {
        let expect = Expect()
        func frame(_ t: Double, bad: Bool) -> ScooterFrame {
            var f = ScooterFrame(t: t)
            f.speedKmh = 20
            f.voltage = bad ? 0 : 50
            f.batteryPct = 80
            return f
        }
        var lift = Plausibility()
        lift.connected(at: 0)
        for i in 0..<250 { _ = lift.check(frame(Double(i) / 10, bad: i % 2 == 0), isPacketA: true) }
        expect(!lift.formatChanged && lift.ignoredReadings > 0, "note 12: garbled readings in the first 25 s (the lift) are dropped one by one but do not trip the watch")
        var real = Plausibility()
        real.connected(at: 0)
        for i in 0..<20 { _ = real.check(frame(Double(i) / 10, bad: false), isPacketA: true) }
        for i in 20..<300 { _ = real.check(frame(Double(i) / 10, bad: true), isPacketA: true) }
        let tripped = real.formatChanged
        for i in 300..<1_200 { _ = real.check(frame(Double(i) / 10, bad: false), isPacketA: true) }
        expect(tripped && !real.formatChanged && real.trustRecovered == 1, "a real change after the warm-up still trips, and trust returns once readings look normal")
        real.connected(at: 200)
        expect(!real.failedShareTripped, "a new connection is judged afresh")
        var x = IgnoredReadings()
        x.add([.speed], speedKmh: 87, batteryPct: nil, tempC: nil)
        x.add([.voltage], speedKmh: nil, batteryPct: nil, tempC: nil)
        expect(x.notes(topSpeedKmh: 32, startPct: 80, endPct: 74, tempPeakC: 40) == ["Top speed ignores a jump to 87 km/h that wasn't real"],
               "note 10: only the speed jump changed a number on the screen, said in plain words")
        expect(x.infoLine == "Ignored readings: speed 1 \u{00B7} voltage 1", "the full counts for \u{22EF} \u{2192} Ride info")
        CheckResults.shared.set("u136", expect.ok ? .pass : .fail, expect.line)
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
