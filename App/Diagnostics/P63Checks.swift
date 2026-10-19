import CorckieCore
import CorckieSim
import Foundation
import SwiftUI

/// P6-3 chunk 1 checks, on made-up input and temporary databases (nothing real is read or written):
/// u67 Add a place saves from the top bar and screens with actions hold the tab bar away (B28), u68 map screens are a fixed map with a
/// scroll view (B29), u69 Home's big button and Where to? row (F-17), u70 Calendar / Rolling stats (F-16), u71 saved per km (F-20) and
/// the weekly line (B30), u72 the last parked spot (V17), u73 the quiet live view (P-4).
@MainActor
enum P63Checks {
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
        runAddPlace()
        runMapScreens()
        runHome()
        runRolling()
        runSavedPerKm()
        runParked()
        runQuietLive()
    }

    // MARK: u67

    private static func runAddPlace() {
        let expect = Expect()
        expect(!PlaceAddRules.canSave(pinned: false, name: "Gym") && !PlaceAddRules.canSave(pinned: true, name: "   ")
               && PlaceAddRules.canSave(pinned: true, name: "Gym"), "Save needs a pin and a name")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let id = try PlaceAddService.add(name: " Gym ", lat: 10.5, lon: 20.5, radiusM: 200, colourId: "green", database: temp)
            let place = try RouteQueries(temp).place(id: id)
            let colours = PlaceColourStore.colours(database: temp)
            expect(place?.name == "Gym" && place?.radiusM == 200 && colours[id] == "green", "the place is written with its trimmed name, circle and colour")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        let bar = TabBarVisibility.shared
        bar.show()
        bar.hold()
        let held = bar.hidden
        bar.release()
        let given = !bar.hidden
        expect(held && given, "a screen with a bottom action holds the tab bar away and gives it back")
        CheckResults.shared.set("u67", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u68

    private static func runMapScreens() {
        let expect = Expect()
        let heights = [852.0, 932.0, 667.0, 1_200.0].map { MapScreenLayout.mapHeight(screenHeight: $0) }
        expect(heights[0] > 330 && heights[0] < 350 && heights[1] > 370 && heights[1] < 376, "the map is about 40% of the screen (\(Int(heights[0])) pt on a 852 pt phone)")
        expect(heights[2] == 280 && heights[3] == 400, "never under 280 pt or over 400 pt")
        expect([852.0, 667.0, 500.0].allSatisfy { $0 - MapScreenLayout.mapHeight(screenHeight: $0) >= 200 }, "the scroll area keeps its room on small screens")
        let bar = TabBarVisibility.shared
        bar.show()
        expect(!bar.hidden && bar.holds == 0, "nothing holds the tab bar on a map screen (no pinned bar, no docked sheet)")
        CheckResults.shared.set("u68", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u69

    private static func runHome() {
        let expect = Expect()
        expect(HomeView.discBase == 250, "the Start / Connect disc is 250 pt")
        expect(HomeView.discCap >= HomeView.discBase && HomeView.discCap + 24 <= 375 - 2 * DS.Space.gutter, "with big text it stops at \(Int(HomeView.discCap)) pt, so it and its halo fit the narrowest iPhone")
        expect(HomeCopy.whereToLine(label: "Work") == "Where to? \u{00B7} Work" && HomeCopy.whereToLine(label: nil) == "Where to? \u{00B7} No destination", "the Where to? row reads \"Where to? \u{00B7} Work\"")
        CheckResults.shared.set("u69", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u70

    private static func runRolling() {
        let expect = Expect()
        let off = 180
        let day: Int64 = 86_400_000
        let now: Int64 = 1_790_000_000_000
        let week = StatsCalc.period(span: .week, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let month = StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let year = StatsCalc.period(span: .year, mode: .rolling, nowMs: now, utcOffsetMin: off)
        expect(week.dayCount == 7 && month.dayCount == 30 && year.dayCount == 365 && month.startMs == now - 30 * day, "Rolling is the last 7 / 30 / 365 days")
        expect(month.label.uppercased() == "LAST 30 DAYS" && year.label == "Last 365 days", "the header reads \"\(month.label.uppercased())\"")
        func ride(_ ago: Int64, _ km: Double) -> StatsRide {
            StatsRide(startAt: now - ago * day, utcOffsetMin: off, kind: "ride", distanceM: km * 1000, totalS: 900, usedPct: 5)
        }
        let rides = [ride(3, 12), ride(20, 18), ride(35, 8), ride(55, 12)]
        let pct = StatsCalc.comparisonPct(rides, span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off, holidayTagged: false)
        expect(abs((pct ?? 0) - 50) < 0.001, "the chip compares 30 km with the 20 km before: +50%")
        let calendarMonth = StatsCalc.period(span: .month, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let bars = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: calendarMonth.dayCount), period: calendarMonth, span: .month, mode: .calendar, utcOffsetMin: off)
        expect(bars.labels.count == calendarMonth.dayCount && bars.labels.last == String(calendarMonth.dayCount), "the month chart has its last label (\(bars.labels.last ?? "-"))")
        let yearBars = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: 365), period: year, span: .year, mode: .rolling, utcOffsetMin: off)
        expect(yearBars.values.count == 12 && abs(yearBars.values.reduce(0, +) - 365) < 0.001, "the rolling year is 12 bars")
        let model = StatsPreview.model("stats-rolling")
        expect(model.mode == .rolling && model.period.label == "Last 30 days", "the Stats preview can show Rolling")
        CheckResults.shared.set("u70", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u71

    private static func runSavedPerKm() {
        let expect = Expect()
        var s = OverallStats()
        s.hasFuelPrice = true
        s.totalKm = 1_054
        s.fuelSavedIls = 900
        s.electricityIls = 90.35
        let v = OverallCalc.savedPerKm(s)
        expect(v.map(OverallCalc.perKmText) == "0.77 \u{20AA}", "809.65 \u{20AA} over 1054 km is \(v.map(OverallCalc.perKmText) ?? "-") per km")
        s.hasFuelPrice = false
        expect(OverallCalc.savedPerKm(s) == nil, "no fuel price, no tile")
        func week(used: Double?, prev: Double?) -> String {
            let a = WeekRide(startAt: 1_790_000_000_000, utcOffsetMin: 180, kind: "ride", distanceM: 5_000, totalS: 900, usedPct: used)
            var b = a
            b.startAt += 86_400_000
            return InsightCatalogue.q22Weekly(weekStart: 0, rides: [a, b], previousWeekKm: prev, nowMs: 1_790_000_000_000).first?.text ?? ""
        }
        expect(!week(used: nil, prev: nil).contains("charges") && !week(used: 0.4, prev: nil).contains("0.0"), "no ~0.0 charges")
        expect(week(used: nil, prev: 2).hasSuffix("\u{25B2} 8 km vs the week before"), "a tiny week before gives km, not a percentage")
        expect(week(used: 22, prev: 20).contains("~0.4 charges") && week(used: nil, prev: 20).hasSuffix("\u{25BC} 50% vs the week before"), "the normal line: charges and a percentage")
        CheckResults.shared.set("u71", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u72

    private static func runParked() {
        let expect = Expect()
        let now: Int64 = 1_790_000_000_000
        let spot = ParkedSpot(lat: 10, lon: 20, endedAtMs: now - 2 * 3_600_000, placeName: "Work")
        expect(ParkedText.line(spot, nowMs: now) == "Parked \u{00B7} Work \u{00B7} 2 h ago", "the row reads \"\(ParkedText.line(spot, nowMs: now))\"")
        let inside = ParkedPin.fraction(lat: 10.001, lon: 20, centreLat: 10, centreLon: 20, spanLatM: MapSnapshotStore.spanLatM, spanLonM: MapSnapshotStore.spanLonM)
        let outside = ParkedPin.fraction(lat: 10.05, lon: 20, centreLat: 10, centreLon: 20, spanLatM: MapSnapshotStore.spanLatM, spanLonM: MapSnapshotStore.spanLonM)
        expect(inside != nil && outside == nil, "the pin lands on the map picture only when the spot is inside it")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try RouteFixtures.insertRide(temp, id: "p1", path: SyntheticRoutes.main, startAt: now - 86_400_000, simulated: false)
            let last = try RouteQueries(temp).pathSamples(rideId: "p1").last
            let found = ParkedLoader.latest(database: temp, simulated: false)
            expect(found != nil && found?.lat == last?.lat && found?.lon == last?.lon, "the spot is the last GPS point of the newest real ride")
            expect(ParkedLoader.latest(database: temp, simulated: true) == nil, "a real spot never shows while only real rides exist for the simulator")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u72", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u73

    private static func runQuietLive() {
        let expect = Expect()
        var d = LiveScreenDriver()
        let fast = (0..<10).map { d.update(LiveInput(scooterSpeedKmh: 52, scooterBatteryPct: 40, phase: .riding, scooterTempC: 50, rideElapsedS: Double($0)), at: Double($0)) }
        expect(fast.allSatisfy { $0.banner == nil } && fast.allSatisfy { $0.tiles.speedKmh == 52 }, "52 km/h is shown and nothing interrupts")
        expect(LiveAlerts.interruptions == [.motorHot], "the hot motor is the only interruption")
        let banned: [LiveBanner] = [.batteryTight, .returnCheck, .destination, .headwind, .starting, .notRiding]
        expect(banned.allSatisfy { !LiveAlerts.isAllowed($0) }, "insight and prompt banners cannot reach the live view")
        var h = LiveScreenDriver()
        _ = h.update(LiveInput(scooterSpeedKmh: 20, scooterBatteryPct: 60, phase: .riding, scooterTempC: 60, rideElapsedS: 0), at: 0)
        let hot = h.update(LiveInput(scooterSpeedKmh: 20, scooterBatteryPct: 60, phase: .riding, scooterTempC: 92, rideElapsedS: 1), at: 1)
        expect(hot.banner?.banner == .hot, "the hot motor still raises its banner")
        var r = LiveScreenDriver()
        r.follow(RouteFollower(destinationName: "Work", path: (0..<31).map { GeoPoint(lat: 10 + Double($0) * 0.0009, lon: -30) }, todayS: 540))
        let arrival = r.update(LiveInput(scooterSpeedKmh: 15, scooterBatteryPct: 15, phase: .riding, lat: 10.001, lon: -30, rideElapsedS: 5, rideDistanceM: 100), at: 5)
        expect(arrival.banner == nil && arrival.arrival != nil && arrival.showHoldToEnd, "the arrival chip and hold-to-end stay, a low way-back battery says nothing")
        CheckResults.shared.set("u73", expect.ok ? .pass : .fail, expect.line)
    }
}
