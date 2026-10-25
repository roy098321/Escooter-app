import CorckieCore
import CorckieSim
import Foundation
import GRDB
import UIKit

/// P6-4 chunk 2 checks, on made-up input and temporary databases (nothing real is read or written):
/// u80 a saved place is a destination (B31), u81 the quick dial ranking and the place icons (F-29), u82 the parked spot is the newest of
/// ride end and last seen, and the odometer rule (B34), u83 riding that was not recorded is found by the odometer (B35).
@MainActor
enum P64C2Checks {
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
        runPlaceDestination()
        runQuickDial()
        runParked()
        runGap()
    }

    private static func place(_ db: AppDatabase, _ id: String, _ name: String?, lat: Double, lon: Double) throws {
        try db.writer.write { d in try PlaceRecord(id: id, name: name, lat: lat, lon: lon, createdAt: 1).insert(d) }
    }

    // MARK: u80

    private static func runPlaceDestination() {
        let expect = Expect()
        let e = PlaceDestination.estimate(distanceM: 3000, usualMps: 5, usualPctPerKm: 3)
        expect(e?.minutes == 10 && abs((e?.usedPct ?? 0) - 9) < 1e-9, "3 km at 5 m/s and 3 %/km is 10 min and 9 %")
        expect(DestinationRules.preRideWarning(name: "Gym", usualNeedPct: 9, batteryPct: 12) != nil
               && DestinationRules.preRideWarning(name: "Gym", usualNeedPct: 9, batteryPct: 60) == nil,
               "the +10 % margin and the reserve decide the F-22 warning, on the honest 9 %")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try place(temp, "p1", "Gym", lat: 10.02, lon: 20)
            try place(temp, "p2", nil, lat: 10.05, lon: 20)
            let loaded = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: GeoPoint(lat: 10, lon: 20), nowMs: 1_790_000_000_000, utcOffsetMin: 0)
            let chip = loaded.chips.first { $0.routeId == "place:p1" }
            expect(loaded.chips.count == 1 && chip != nil, "a named place without a route is a destination; a nameless one is not")
            expect(chip?.timeText == nil && chip?.note == "no rides there yet" && chip?.usualNeedPct == nil, "B44: no ride ended there, so no time and no battery figure")
            expect(QuickDialLoader.summary(chip: nil) == "No destination" && QuickDialLoader.summary(chip: chip).hasPrefix("Gym \u{00B7}"),
                   "the line under the icons says what was chosen")
            let nowhere = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: nil)
            expect(nowhere.chips.first?.timeText == nil, "without a phone location the place is still listed, without numbers")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u80", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u81

    private static func runQuickDial() {
        let expect = Expect()
        expect(PlaceIcon.symbols.count == 16 && Set(PlaceIcon.symbols).count == 16, "the grid has 16 different symbols")
        let missing = PlaceIcon.symbols.filter { UIImage(systemName: $0) == nil }
        expect(missing.isEmpty, "every symbol exists on this iOS" + (missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))"))
        expect(PlaceIcon.clean("maya") == "MA" && PlaceIcon.clean("\u{1F600}") == "", "typed letters are 1 or 2, never an emoji")
        expect(QuickDial.slotCount(accessibilitySize: false) == 3 && QuickDial.slotCount(accessibilitySize: true) == 2, "3 slots, 2 at the largest text sizes")
        let ranked = QuickDial.slots([QuickDialPlace(id: "a", name: "A", visits: 9), QuickDialPlace(id: "b", name: "B", visits: 20),
                                      QuickDialPlace(id: "c", name: "C", visits: 2, pinOrder: 1)], count: 3)
        expect(ranked == ["c", "b", "a"], "pinned first, then the most visited (\(ranked.joined()))")
        expect(QuickDial.summary(name: "Maya's house", minutes: 12, needPct: 9) == "Maya's house \u{2022} 12 mins \u{2022} 9% battery"
               && QuickDial.summary(name: nil, minutes: nil, needPct: nil) == "No destination", "the line reads as agreed")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try place(temp, "p1", "Maya's house", lat: 10.01, lon: 20)
            try QuickDialLoader.setIcon(.letters("M"), placeId: "p1", database: temp)
            try QuickDialLoader.setPin(2, placeId: "p1", database: temp)
            expect(QuickDialLoader.icons(temp)["p1"] == .letters("M") && QuickDialLoader.pins(temp)["p1"] == 2, "icon and slot are stored per place and read back")
            let loaded = QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: nil)
            expect(loaded.items.first?.icon == .letters("M") && loaded.items.first?.key == "place:p1", "the pinned place is on the quick dial with its icon")
            try QuickDialLoader.setPin(nil, placeId: "p1", database: temp)
            try QuickDialLoader.setIcon(nil, placeId: "p1", database: temp)
            expect(QuickDialLoader.pins(temp).isEmpty && QuickDialLoader.icons(temp).isEmpty, "Show on Home off and automatic icon remove the settings")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u81", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u82

    private static func runParked() {
        let expect = Expect()
        let hour: Int64 = 3_600_000
        let now: Int64 = 1_790_000_000_000
        let ride = ParkedSpot(lat: 1, lon: 1, endedAtMs: now - 5 * hour, placeName: "Work")
        let seen = LastSeenSpot(lat: 2, lon: 2, atMs: now - 2 * hour, odoKm: 100)
        let newest = ParkedChoice.choose(ride: ride, seen: seen, rideEndOdoKm: 90, currentOdoKm: 100)
        expect(newest?.lat == 2 && newest.map { ParkedText.line($0, nowMs: now) } == "Last seen here \u{00B7} 2 h ago", "the newer last-seen spot wins: \"Last seen here \u{00B7} 2 h ago\"")
        let older = ParkedChoice.choose(ride: ride, seen: LastSeenSpot(lat: 3, lon: 3, atMs: now - 9 * hour), rideEndOdoKm: 90, currentOdoKm: 90)
        expect(older?.lat == 1 && older.map { ParkedText.line($0, nowMs: now) } == "Parked \u{00B7} Work \u{00B7} 5 h ago", "the newer ride end wins: \"Parked \u{00B7} Work \u{00B7} 5 h ago\"")
        let moved = ParkedChoice.choose(ride: ride, seen: nil, rideEndOdoKm: 90, currentOdoKm: 94)
        expect(moved?.confident == false && moved.map { ParkedText.line($0, nowMs: now) } == "Last seen \u{00B7} Work \u{00B7} 5 h ago", "the odometer went up: \"Last seen\", no confident pin")
        expect(LastSeenSpot.fixUsable(accuracyM: 30, ageS: 60) && !LastSeenSpot.fixUsable(accuracyM: 80, ageS: 60) && !LastSeenSpot.fixUsable(accuracyM: 30, ageS: 300),
               "a phone fix counts only within 50 m and 2 minutes")
        CheckResults.shared.set("u82", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u83

    private static func runGap() {
        let expect = Expect()
        expect(abs((OdometerGap.km(connectKm: 104.2, lastRideEndKm: 100, lastGapToKm: nil) ?? 0) - 4.2) < 1e-9
               && OdometerGap.km(connectKm: 100.2, lastRideEndKm: 100, lastGapToKm: nil) == nil
               && OdometerGap.km(connectKm: 104.2, lastRideEndKm: nil, lastGapToKm: nil) == nil
               && OdometerGap.km(connectKm: 104.2, lastRideEndKm: 100, lastGapToKm: 104.2) == nil,
               "4.2 km is a gap; 0.2 km, an unknown ride end and an already noted gap are not")
        expect(OdometerGap.homeLine(km: 4.2) == "4.2 km ridden without recording" && OdometerGap.rideRow(km: 4.2) == "Not recorded \u{00B7} 4.2 km", "the Home line and the Rides row read as agreed")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let now: Int64 = 1_790_000_000_000
            _ = try RouteFixtures.insertRide(temp, id: "g1", path: SyntheticRoutes.main, startAt: now - 86_400_000, simulated: false)
            expect(GapStore.detect(temp, connectOdoKm: 500, nowMs: now) == nil, "a ride without a stored end odometer gives no verdict")
            try temp.writer.write { d in try d.execute(sql: "UPDATE ride SET odoEndKm = 100 WHERE id = 'g1'") }
            expect(GapStore.detect(temp, connectOdoKm: 100.1, nowMs: now) == nil, "0.1 km more is rounding")
            let gap = GapStore.detect(temp, connectOdoKm: 104.2, nowMs: now)
            expect(abs((gap?.km ?? 0) - 4.2) < 1e-9, "4.2 km more is stored as a gap")
            expect(GapStore.detect(temp, connectOdoKm: 104.2, nowMs: now + 1000) == nil && GapStore.all(temp).count == 1, "the same gap is not stored twice")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u83", expect.ok ? .pass : .fail, expect.line)
    }
}
