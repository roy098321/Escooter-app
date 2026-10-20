import CorckieCore
import CorckieSim
import Foundation
import UIKit

/// P6-5 checks (owner feedback on build 251), on made-up input and temporary databases (nothing real is read or written):
/// u110 a place's time comes only from rides that ended there, "no rides yet" / "estimate after 2", and "You are here" (B44, B45, B46),
/// u111 the boot reading of the scooter is not believed: 100, 100, 100, 64, 64, 64 settles on 64 (B50),
/// u112 the Past weeks metric values, the photo frame, the pins, the glyph colour and the neutral arrival symbol (B41, B47, F-29b).
@MainActor
enum P65Checks {
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
        runPlaceEstimates()
        runBootSettle()
        runMetrics()
    }

    private static let base: Int64 = 1_790_000_000_000

    // MARK: u110

    private static func runPlaceEstimates() {
        let expect = Expect()
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            try temp.writer.write { d in
                try PlaceRecord(id: "g", name: "Grandma", lat: 10.0, lon: 20.0, createdAt: 1).insert(d)
                try PlaceRecord(id: "o", name: "Old workplace", lat: 10.05, lon: 20.0, createdAt: 2).insert(d)
            }
            let none = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: GeoPoint(lat: 10.0, lon: 20.0), nowMs: base, utcOffsetMin: 0)
            let gran = none.chips.first { $0.routeId == "place:g" }
            expect(gran?.timeText == nil && gran?.note == "no rides there yet", "B44: Grandma has no ride, so no time and \"no rides there yet\"")
            expect(QuickDialLoader.summary(chip: gran) == "Grandma \u{00B7} no rides there yet", "the line under the icons says it")
            expect(gran?.here == true && none.chips.first { $0.routeId == "place:o" }?.here == false, "B46: only the place the phone is inside is \"here\"")

            let path = SyntheticRoutes.main
            _ = try RouteFixtures.insertRide(temp, id: "o1", path: path, startAt: base - 2 * 86_400_000, simulated: false)
            try store.setPlaces(rideId: "o1", startPlaceId: nil, endPlaceId: "o")
            let one = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: nil, nowMs: base, utcOffsetMin: 0)
            expect(one.chips.first { $0.routeId == "place:o" }?.note == "1 ride there \u{00B7} estimate after 2", "B45: one ride says how many more are needed")
            _ = try RouteFixtures.insertRide(temp, id: "o2", path: path, startAt: base - 86_400_000, simulated: false)
            try store.setPlaces(rideId: "o2", startPlaceId: nil, endPlaceId: "o")
            let two = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: nil, nowMs: base, utcOffsetMin: 0)
            let old = two.chips.first { $0.routeId == "place:o" }
            expect(old?.timeText != nil && old?.arriveText != nil && old?.note == nil, "B45: two rides that ended there give an estimate (\(old?.timeText ?? "none"))")
            expect(two.rows.first { $0.placeId == "o" }?.timeText == old?.timeText, "the Where to? sheet row shows the same time")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        expect(PlaceRides.verdict(rides: [], nowMs: base, utcOffsetMin: 0) == .none, "no rides = none")
        expect(PlaceHere.tapLine(name: "Home") == "You're at Home", "tapping the place you are in says so")
        CheckResults.shared.set("u110", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u111

    private static func runBootSettle() {
        let expect = Expect()
        var s = BootSettle()
        var shown: [Int?] = []
        for (i, pct) in [100, 100, 100, 64, 64, 64].enumerated() { shown.append(s.reading(pct: pct, at: Double(i))) }
        expect(shown.dropLast().allSatisfy { $0 == nil } && shown.last == 64, "B50: 100, 100, 100, 64, 64, 64 shows nothing until it settles on 64")
        expect(s.notifyPct == 64, "the notification takes 64, never the boot 100")
        var full = BootSettle()
        var early: Int?
        for t in 0..<8 { early = full.reading(pct: 100, at: Double(t)) ?? early }
        expect(early == nil && full.reading(pct: 100, at: 8) == 100, "a scooter that really is full is believed after 8 s")
        var flap = BootSettle()
        for (i, pct) in [100, 97, 100, 96, 100, 95, 100, 94].enumerated() { flap.reading(pct: pct, at: Double(i) * 2) }
        flap.tick(at: 15)
        expect(flap.gaveUp && flap.notifyPct == nil && flap.displayPct == 94, "never stable: after 15 s no % in the notification, the screen shows the latest")
        let center = Center()
        let n = GoingForARideNotifier(sender: center, logger: center)
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 64, at: 5, appActive: false, rideActive: false)
        expect(center.titles == ["Scooter on \u{00B7} 64%"], "the rule sends the settled value: \(center.titles.first ?? "nothing sent")")
        CheckResults.shared.set("u111", expect.ok ? .pass : .fail, expect.line)
    }

    private final class Center: NotificationSending, MessageLogging {
        var titles: [String] = []
        func send(id: String, title: String, body: String, soundName: String) { titles.append(title) }
        func remove(id: String) {}
        func log(_ entry: MessageLogEntry) {}
    }

    // MARK: u112

    private static func runMetrics() {
        let expect = Expect()
        let bar = WeekBar(start: base, km: 61.4, rides: 8, seconds: 4800, savedIls: 34.4)
        expect(PastWeeksMetric.allCases.map { $0.valueText(bar) } == ["61 km", "8 rides", "1 h 20", "\u{20AA}34"], "B41: the four metrics read 61 km, 8 rides, 1 h 20, \u{20AA}34")
        expect(PastWeeksMetric.km.cardTitle == "Past weeks \u{00B7} km" && PastWeeksMetric.from(stored: nil) == .km, "the title names the metric; km is the default")
        expect(PastWeeksMetric.weekLabel(start: 1_788_652_800_000, utcOffsetMin: 0) == "6 Sep", "the week label is its first day")
        let week = 7 * OutsideTime.dayMs
        let start = InsightWeek.start(ms: base, utcOffsetMin: 0) - 2 * week + OutsideTime.dayMs
        let rides = [StatsRide(startAt: start, utcOffsetMin: 0, kind: "ride", distanceM: 10_000, totalS: 1800, usedPct: 10),
                     StatsRide(startAt: start + 3_600_000, utcOffsetMin: 0, kind: "ride", distanceM: 5_000, totalS: 900, usedPct: 5)]
        let bars = WeekBars.make(statsRides: rides, prices: StatsPrices(packWh: 800, fuelFallbackIls: 8.0), nowMs: base, utcOffsetMin: 0)
        let found = bars.first { $0.rides == 2 }
        expect(found?.km == 15 && found?.seconds == 2700 && (found?.savedIls ?? 0) > 0, "a week made from rides carries km, time and \u{20AA} saved")
        let frame = PhotoFrame(scale: 1, dx: 5, dy: 5).clamped(imageAspect: 1.5)
        expect(frame.dy == 0 && frame.dx > 0 && frame.dx < 0.5, "the photo always covers the card: a wide photo moves sideways only")
        expect(QuickDialSlot.pin("d", in: ["a": 1, "b": 2, "c": 3]) == .needsReplace(candidates: ["a", "b", "c"]), "the 4th pin asks which to replace")
        expect(PlaceColours.glyphIsDark(hex: PlaceColours.hex("yellow")) && !PlaceColours.glyphIsDark(hex: PlaceColours.hex("blue")),
               "dark glyph on yellow, white on blue")
        let symbol = "mappin.and.ellipse"
        expect(UIImage(systemName: symbol) != nil && UIImage(systemName: QuickDialSlot.freeRideSymbol) != nil, "B47: the neutral arrival pin and the question mark symbol exist on this iOS")
        CheckResults.shared.set("u112", expect.ok ? .pass : .fail, expect.line)
    }
}
