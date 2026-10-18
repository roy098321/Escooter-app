import CorckieCore
import CorckieSim
import Foundation

/// P6-1 fix build (T-04 field data), one check per fix, all on made-up data or a temporary database (the real database is only
/// read, for the re-link line of u51): u51 places on every ride + the way back + the re-link pass (B24), u52 every ride_sample
/// column written (B25), u53 a switch-off without the flag is the scooter off with no gap (B26), u54 "Scooter on" only with a
/// live battery % (B27).
enum P61Checks {
    private static let base: Int64 = 1_790_000_000_000
    private static let day: Int64 = 86_400_000

    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " · ") }
    }

    // MARK: u51 (B24)

    static func runPlaces(real: AppDatabase?) {
        let expect = Expect()
        let back = SyntheticRoutes.reversed(SyntheticRoutes.main)
        let toHome = SyntheticRoutes.offset(SyntheticRoutes.loop, by: (x: 3_000, y: 0)) + [(x: 0, y: 0)]
        func at(_ k: Double) -> Int64 { base + Int64(k * Double(day)) }
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            func ride(_ id: String, _ path: [SyntheticRoutes.XY], _ k: Double) throws -> RouteProcessResult? {
                try RouteFixtures.insertRide(temp, id: id, path: path, startAt: at(k))
                return try RouteProcessor.process(rideId: id, database: temp)
            }
            _ = try ride("a", SyntheticRoutes.main, 0)
            let b = try ride("b", SyntheticRoutes.main, 1)
            let ab = try b?.routeId.flatMap { try store.route(id: $0) }
            let c = try ride("c", back, 1.4)
            let cLink = try store.link(rideId: "c")
            expect(c?.outcome == .suggested && c?.routeId != nil && c?.routeId != ab?.id && cLink?.startPlaceId == ab?.toPlaceId
                   && cLink?.endPlaceId == ab?.fromPlaceId && RouteService.offer(rideId: "c", database: temp)?.headline == "Save as route?",
                   "way back offered after 1 trip, on both places")
            _ = try ride("f", toHome, 2)
            let f = try store.link(rideId: "f")
            expect(f?.routeId == nil && f?.startPlaceId == nil && f?.endPlaceId == ab?.fromPlaceId, "ride from elsewhere ends at Home (no route)")
        } catch {
            expect(false, "ride close: \(error.localizedDescription)")
        }
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            // as build 164 left them: a route Home → Work, and three rides that got nothing
            for (id, k) in [("a", 0.0), ("b", 1.0)] {
                try RouteFixtures.insertRide(temp, id: id, path: SyntheticRoutes.main, startAt: at(k))
                _ = try RouteProcessor.process(rideId: id, database: temp)
            }
            for (id, path, k) in [("c", back, 1.4), ("f", toHome, 2.0), ("g", back, 2.4)] {
                try RouteFixtures.insertRide(temp, id: id, path: path, startAt: at(k))
            }
            let before = try temp.allRowCounts()
            let r = try RouteRelink.runOnce(database: temp)
            let after = try temp.allRowCounts()
            let verdict = UpdateCheckRules.verdict(before: before, after: after)
            let wayBack = try store.link(rideId: "c")?.routeId
            let gRoute = try store.link(rideId: "g")?.routeId
            expect(r?.placedAfter == 5 && r?.routedAfter == 4 && wayBack != nil && gRoute == wayBack,
                   "re-link: \(r?.line ?? "did not run")")
            expect(verdict.passed, "no row lost (a9 rule): \(verdict.passed ? "ok" : verdict.note)")
            let second = try RouteRelink.runOnce(database: temp)
            let again = try RouteRelink.run(database: temp)
            let rowsAgain = try temp.allRowCounts()
            expect(second == nil && again.routedAfter == again.routedBefore && again.routesAfter == again.routesBefore && rowsAgain == after,
                   "runs once; again changes nothing")
        } catch {
            expect(false, "re-link: \(error.localizedDescription)")
        }
        // This phone's own pass (read only)
        let mine = real.flatMap { try? RideQueries($0).setting(key: RouteRelink.settingKey) } ?? "not run yet"
        CheckResults.shared.set("u51", expect.ok ? .pass : .fail, expect.line + " · this phone: " + mine)
    }

    // MARK: u52 (B25)

    static func runSampleColumns() async {
        let expect = Expect()
        func text(_ name: String) -> String? {
            Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let f3 = text("F3_ride2_merged"), let loc = text("F4_ride2_location"), let baro = text("F4_ride2_barometer"),
              let fixture = SimFixture.all.first(where: { $0.id == "F3" }), let start = LogReader.mergedStartTimeOfDayS(f3) else {
            CheckResults.shared.set("u52", .fail, "Ride-2 fixtures not found in the app")
            return
        }
        do {
            let stream = SimStream(scooter: try fixture.events(from: f3),
                                   phone: try PhoneSource.events(locationText: loc, barometerText: baro, scooterStartTimeOfDayS: start))
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let rec = Recorder(database: temp, simulated: true, build: AppInfo.build, stateURL: Recorder.stateURL(for: temp),
                               epochOffset: Date().timeIntervalSince1970 - 86_400 - (stream.scooter.first?.t ?? 0))
            await rec.process(RecorderRunner.inputs(stream))
            guard let rideId = await rec.closedRideIds.first else {
                CheckResults.shared.set("u52", .fail, "No ride closed")
                return
            }
            let columns = ["gear", "capKmh", "brake", "light", "courseDeg", "altFixedM", "moving", "stopId", "distanceM"]
            let total = try RideQueries(temp).sampleCount(rideId: rideId)
            let counts: [(String, Int)] = try temp.writer.read { db in
                try columns.map { c in
                    (c, try Int.fetchOne(db, sql: "SELECT COUNT(\(c)) FROM ride_sample WHERE rideId = ?", arguments: [rideId]) ?? 0)
                }
            }
            let stops = try RideQueries(temp).stops(rideId: rideId)
            let longStop = stops.contains { ($0.endT ?? $0.startT) - $0.startT >= 10_000 }
            let empty = counts.filter { $0.1 == 0 && ($0.0 != "stopId" || longStop) }.map { $0.0 }
            let full = counts.filter { ["moving", "distanceM"].contains($0.0) }.allSatisfy { $0.1 == total }
            expect(empty.isEmpty, empty.isEmpty ? "every column has values (\(total) samples)" : "empty: " + empty.joined(separator: ", "))
            expect(full, "moving and distance on every sample")
        } catch {
            expect(false, error.localizedDescription)
        }
        CheckResults.shared.set("u52", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u53 (B26)

    static func runScooterOff() {
        let expect = Expect()
        for id in ["END-A", "AUTO-OFF"] {
            guard let s = SyntheticScenario.all.first(where: { $0.id == id })?.build() else {
                expect(false, "\(id) scenario missing")
                continue
            }
            let r = EngineRunner.run(s)
            guard let end = r.ends.first else {
                expect(false, "\(id): no end")
                continue
            }
            let gap = end.metrics(r.samples[end.ride.seq] ?? []).gapScooterS
            expect(end.reason == .scooterOff && gap < 0.5 && end.ride.gapList.isEmpty,
                   "\(id): ended by \(end.reason.rawValue), scooter gap \(Int(gap.rounded())) s")
        }
        CheckResults.shared.set("u53", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u54 (B27)

    private final class Center: NotificationSending, MessageLogging {
        var titles: [String] = []
        func send(id: String, title: String, body: String, soundName: String) { titles.append(title) }
        func remove(id: String) {}
        func log(_ entry: MessageLogEntry) {}
    }

    static func runLiveBattery() {
        let expect = Expect()
        let center = Center()
        let n = GoingForARideNotifier(sender: center, logger: center)
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.packet(at: 0.3)
        n.tick(at: 1.5, appActive: false, rideActive: false)
        n.tick(at: 2.4, appActive: false, rideActive: false)
        expect(center.titles == ["Scooter on"], "no live % within 2 s: \(center.titles.first ?? "nothing sent")")
        var stale = ScooterFrame(t: 100)
        stale.batteryPct = 11
        stale.ageA = 0
        expect(GoingForARideContent.liveBatteryPct(stale, now: 900) == nil && GoingForARideContent.liveBatteryPct(stale, now: 100.5) == 11,
               "stale frame gives no %")
        var p = ScooterPipeline()
        var v = PacketEncoder.Values()
        v.batteryPct = 11
        p.handle(TimedScooterEvent(t: 0, event: .connected))
        p.handle(TimedScooterEvent(t: 1, event: .packet(PacketEncoder.packetA(v))))
        p.handle(TimedScooterEvent(t: 600, event: .connected))
        expect(p.frame == nil, "a new connection starts with no frame")
        CheckResults.shared.set("u54", expect.ok ? .pass : .fail, expect.line)
    }
}
