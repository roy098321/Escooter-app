import CorckieCore
import CorckieSim
import Foundation
import GRDB

/// Batch 102.011126.00 checks, on made-up input only (nothing real is read or written).
/// u168 the route line is short solid pieces of the lab's B width (R1 / note 17),
/// u166 the Battery layer marks each first drop below 10 % steps (R2),
/// u169 Home's last reading with its time and the labelled charge target (R3 / B64),
/// u170 one full time on the charging screen, the estimate starts at the last reading (R5 / B65),
/// u172 the export holds every ride of this phone's Rides list (B67; read only),
/// u173 place outlines: inside / outside, the editor, the outline replaces the circle, "Around" rides (note 18),
/// u175 a trip time only at the trip's start place (B66),
/// u176 ride graph chips: a tap adds / removes, ⇄ flips (note 15), u177 graph gestures: pinch = time, swipe up / down = scale (note 16),
/// u179 insights from whole rides: About N more rides, partial graph with a band, one-line hints, the plan's order,
/// u180 the charging speed learned from Plug in.
@MainActor
enum B102Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runRoutePieces()
        runBatteryMarks()
        runLastReading()
        runChargeAgree()
        runExportHoldsList()
        runPlaceOutline()
        runTripFromHere()
        runChipFlip()
        runGraphGestures()
        runRideLevel()
        runChargeRate()
    }

    // MARK: u180

    /// Insights plan 3a: three made-up Plug in charges teach the speed; a full one and an unmeasured one are left out
    private static func runChargeRate() {
        let expect = Expect()
        let h: Double = 3_600_000
        func e(_ from: Double, _ to: Double, _ hours: Double, _ measured: Bool = true) -> ChargeLogEntry {
            ChargeLogEntry(id: UUID().uuidString, startMs: 0, endMs: Int64(hours * h), startPct: from, endPct: to, measured: measured)
        }
        let log = [e(30, 70, 2.5), e(40, 80, 2.5), e(20, 60, 4), e(50, 100, 3), e(50, 80, 2, false)]
        let l = ChargeRateLearner.learn(log)
        expect(l?.charges == 3 && abs((l?.ratePctPerHour ?? 0) - 16) < 0.05, "learned \(l?.ratePctPerHour ?? 0) %/h from \(l?.charges ?? 0) charges")
        expect(ChargeRateLearner.learn(Array(log.prefix(2))) == nil, "two charges: the measured 13.6 %/h stays")
        let s = ChargeSession(startPct: 60, startMs: 0, ratePctPerHour: l?.ratePctPerHour, rateFromCharges: l?.charges)
        expect(PlugIn.why(s, .battery(100), utcOffsetMin: 0).contains("learned from your last 3 charges"), "estimated says where the speed comes from")
        let mine = ChargeTimer.shared.learnedRate
        expect(true, "this phone: " + (mine.map { "\($0.ratePctPerHour) %/h from \($0.charges) charges" } ?? "not learned yet (13.6 %/h)"))
        expect.report("u180")
    }

    // MARK: u179

    /// Insights plan: made-up rides between 31 and 41 km/h; a read with a range, a band below 30 km/h and a hint for it; few rides say how many more
    private static func runRideLevel() {
        let expect = Expect()
        let sample = InsightsPreview.rideLevelSample()
        let speed = RideLevelInsights.make(.speedCost, rides: sample)
        expect(speed.range != nil, "a read from 12 made-up rides: \(speed.range ?? "none") \(speed.rangeContext ?? "")")
        let thin = speed.curve.first { $0.x < 25 }
        expect(thin?.covered == false && (thin?.hi ?? 0) > (thin?.lo ?? 0), "no rides under 30 km/h: a dashed band there, not a line")
        expect(speed.hint?.hasPrefix("Ride steady at 15") == true, "hint: " + (speed.hint ?? "none"))
        let few = RideLevelInsights.make(.hills, rides: Array(sample.prefix(2)))
        expect(few.progressLine == "About 2 more rides for a first read", "two rides: " + few.progressLine)
        let temp = RideLevelInsights.make(.temperature, rides: sample)
        expect(temp.progressLine == "Waiting for colder days", "warm days only: " + temp.progressLine)
        expect(RideLevelInsights.rank("hills") < RideLevelInsights.rank("speedCost") && RideLevelInsights.rank("wind") < RideLevelInsights.rank("departure"),
               "order: Hills, Speed, Battery over time, Temperature, Wind, Best time to leave")
        expect.report("u179")
    }

    // MARK: u176

    /// Note 15 (A): tap = add / remove only; a selected chip with a derived line has ⇄ ("Speed ⇄ Accel"); the last chip stays
    private static func runChipFlip() {
        let expect = Expect()
        var picks = GraphChips(available: [.speed, .accel, .battery, .batteryPerKm, .power])
        picks.tap(.battery)
        expect(picks.isOn(.battery) && picks.highlighted == .battery, "a tap adds Battery and gives it the axis")
        picks.tap(.battery)
        expect(!picks.isOn(.battery), "a second tap takes it off (no derived step any more)")
        expect(picks.canFlip(.speed) && !picks.canFlip(.battery), "\u{21C4} only on a selected chip with a derived line")
        picks.flip(.speed)
        expect(picks.label(.speed) == "Speed \u{2192} Accel", "\u{21C4} on Speed: " + picks.label(.speed))
        picks.tap(.power)
        expect(!picks.canFlip(.power), "Power has no \u{21C4}")
        picks.tap(.speed); picks.tap(.power)
        expect(picks.on == [.power] || picks.on.count == 1, "the last line stays on")
        expect.report("u176")
    }

    // MARK: u177

    /// Note 16: a drag is told apart once; up = stretch, down = relax, clamped
    private static func runGraphGestures() {
        let expect = Expect()
        expect(RideGraph.dragAxis(dx: 2, dy: -14) == .upDown && RideGraph.dragAxis(dx: 14, dy: 5) == .sideways && RideGraph.dragAxis(dx: 3, dy: 4) == nil,
               "up-down vs sideways decided after 10 pt")
        expect(RideGraph.swipeScale(base: 1, dyFraction: -0.3) > 1 && RideGraph.swipeScale(base: 2, dyFraction: 0.3) < 2, "swipe up stretches, down relaxes")
        expect(RideGraph.swipeScale(base: 1, dyFraction: -10) == 20, "clamped")
        expect.report("u177")
    }

    // MARK: u175

    /// B66 on a temporary database: two made-up Home → Uni rides; Uni's chip has a time at Home only
    private static func runTripFromHere() {
        let expect = Expect()
        let base: Int64 = 1_790_000_000_000
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try temp.writer.write { d in
                try PlaceRecord(id: "home", name: "Home", lat: 10.0, lon: 20.0, createdAt: 1).insert(d)
                try PlaceRecord(id: "uni", name: "Uni", lat: 10.05, lon: 20.0, createdAt: 2).insert(d)
            }
            for (i, id) in ["r1", "r2"].enumerated() {
                _ = try RouteFixtures.insertRide(temp, id: id, path: SyntheticRoutes.main, startAt: base - Int64(i + 1) * 86_400_000, simulated: false)
                try RouteQueries(temp).setPlaces(rideId: id, startPlaceId: "home", endPlaceId: "uni")
            }
            func uni(_ at: GeoPoint) -> WhereToChip? {
                QuickDialLoader.load(database: temp, routeChips: [], slots: 3, from: at, nowMs: base, utcOffsetMin: 0).chips.first { $0.routeId == "place:uni" }
            }
            let home = uni(GeoPoint(lat: 10.0, lon: 20.0))
            expect(home?.timeText != nil, "at Home: Uni \u{2022} \(home?.timeText ?? "no time")")
            let there = uni(GeoPoint(lat: 10.05, lon: 20.0))
            expect(there?.timeText == nil && there?.note == nil && QuickDialLoader.summary(chip: there) == "Uni", "at Uni: just Uni")
            expect(uni(GeoPoint(lat: 10.02, lon: 20.0))?.timeText == nil, "somewhere else: just the name")
        } catch {
            expect(false, "the temporary database failed: \(error.localizedDescription)")
        }
        expect.report("u175")
    }

    // MARK: u173

    /// Note 18 on a made-up 400 × 200 m campus: the outline holds its far end (a 100 m circle does not), the editor adds / inserts /
    /// undoes, "you're here" follows the outline, a ride that stays inside is an Around ride
    private static func runPlaceOutline() {
        let expect = Expect()
        let o = GeoPoint(lat: 10, lon: 20)
        func at(_ x: Double, _ y: Double) -> GeoPoint {
            GeoPoint(lat: o.lat + y / 111_320, lon: o.lon + x / (111_320 * cos(o.lat * .pi / 180)))
        }
        var editor = OutlineEditor()
        editor.add(at(0, 0)); editor.add(at(400, 0)); editor.add(at(400, 200))
        editor.insertMidpoint(after: 2)
        editor.move(3, to: at(0, 200))
        expect(editor.points.count == 4 && editor.areaLine == "Area 8.0 ha", "draw 3 corners, insert one, drag it: " + (editor.areaLine ?? "no area"))
        editor.undo()
        expect(editor.points[3] != at(0, 200), "undo takes back the drag")
        let campus = [at(0, 0), at(400, 0), at(400, 200), at(0, 200)]
        let centre = PlaceOutline.centre(campus) ?? o
        expect(PlaceHere.isHere(phone: at(390, 100), place: centre, radiusM: 100, outline: campus)
               && !PlaceHere.isHere(phone: at(390, 100), place: centre, radiusM: 100), "you're here at the far end only with the outline")
        expect(!PlaceHere.isHere(phone: at(200, 220), place: centre, radiusM: 100, outline: campus), "20 m outside the line is not here")
        var book = RouteBook(places: [PlaceInfo(id: "uni", name: "Uni", point: centre, outline: campus)])
        let inside: [GeoPoint] = (0...30).map { (k: Int) -> GeoPoint in
            let x: Double = 20 + Double(k) * 12
            let y: Double = 50 + Double(k % 5) * 20
            return at(x, y)
        }
        let u = book.ingest(RoutedRide(id: "a", startAt: 0, distanceM: 1_200, shape: TripShape(start: inside.first, end: inside.last, path: inside)), pool: [])
        expect(u.assignments.first?.outcome == .around && AroundRide.title("Uni") == "Around Uni", "a ride that stays inside is Around Uni")
        expect.report("u173")
    }

    // MARK: u172

    /// B67: the export's rides = the Rides list (real rides), read only on this phone's database
    private static func runExportHoldsList() {
        let expect = Expect()
        guard let db = AppModel.shared.database else {
            CheckResults.shared.set("u172", .info, "No database open")
            return
        }
        let listed = ((try? RideQueries(db).rides()) ?? []).filter { !$0.isSimulated }
        let exported = Set((try? db.writer.read { try ExportAll.rideIds($0) }) ?? [])
        let missing = listed.filter { !exported.contains($0.id) }
        expect(missing.isEmpty, "\(listed.count) rides in the list, \(exported.count) in the export"
               + (missing.isEmpty ? "" : "; missing: " + missing.prefix(3).map { "\($0.kind) \($0.id.prefix(6))" }.joined(separator: ", ")))
        expect.report("u172")
    }

    // MARK: u170

    /// R5 / B65: the pill and the card show the same honest full time; the notification still waits +5 %
    private static func runChargeAgree() {
        let expect = Expect()
        let s = ChargeSession(startPct: 66, startMs: 1_790_000_000_000, pctPerKm: 2.0, reservePct: 10, scooterName: "Test")
        expect(ChargeModel.pct(s, atMs: s.startMs) == 66, "the estimate starts at the last reading (66 %)")
        expect(PlugIn.shownMs(s, .battery(100)) == ChargeModel.fullMs(s), "the sheet shows the same full time as the card")
        expect(PlugIn.chargeLineAlert(s, .battery(100), utcOffsetMin: 0) == "Charge to 100%", "under the charge line no second full time")
        expect(PlugIn.alertMs(s, .battery(100)) == ChargeModel.notifyFullMs(s), "the full alert still waits +5 %")
        expect.report("u170")
    }

    // MARK: u169

    /// R3 / B64: "66% · 07:49" from the ride's resting reading, not a dip seen at the same stop; the pill says "Charge to 100%"
    private static func runLastReading() {
        let expect = Expect()
        let ride = BatteryReading(pct: 66, ms: 1_000_000_000)
        let dip = BatteryReading(pct: 62, ms: 1_000_000_000 + 120_000)
        let picked = LastReading.pick(seen: dip, rideEnd: ride)
        expect(picked == ride, "the ride's resting 66 % wins over a 62 % seen 2 min later")
        let later = BatteryReading(pct: 90, ms: 1_000_000_000 + 3 * 3_600_000)
        expect(LastReading.pick(seen: later, rideEnd: ride) == later, "a reading hours later wins")
        let text = LastReading.text(ride, utcOffsetMin: 0)
        expect(text.hasPrefix("66% \u{00B7} ") && text.count == 11, "reads " + text)
        expect(PlugAlert.default.targetText == "Charge to 100%", "the target pill reads Charge to 100%")
        expect.report("u169")
    }

    // MARK: u166

    /// R2: 100 → 64 % gives 90 / 80 / 70; a 90 ↔ 89 flicker gives one 90; no mark for the start
    private static func runBatteryMarks() {
        let expect = Expect()
        let full = B101LateChecks.madeUpRide(37, power: { _ in 300 }, battery: { 100 - $0 })
        let levels = BatteryMarks.marks(full).map(\.text)
        expect(levels == ["90%", "80%", "70%"], "100 \u{2192} 64 %: " + levels.joined(separator: " "))
        let flicker = [95, 90, 89, 90, 89, 90, 88]
        let one = BatteryMarks.marks(B101LateChecks.madeUpRide(flicker.count, power: { _ in 300 }, battery: { flicker[$0] }))
        expect(one.map(\.level) == [90], "a 90 \u{2194} 89 flicker gives one mark")
        let start = BatteryMarks.marks(B101LateChecks.madeUpRide(3, power: { _ in 300 }, battery: { [90, 89, 85][$0] }))
        expect(start.isEmpty, "no mark for the starting level")
        expect(LayerView(.battery).showsBatteryMarks && !LayerView(.speed).showsBatteryMarks, "on the Battery layer only")
        expect.report("u166")
    }

    // MARK: u168

    /// R1 / note 17: even 6 pt pieces, butt caps, colour changes along the line, same-colour neighbours joined
    private static func runRoutePieces() {
        let expect = Expect()
        let pts = B101LateChecks.madeUpRide(300, power: { _ in 300 }, battery: { _ in 80 }, speed: { 10 + Double($0 % 60) / 2 })
        let stretches = RideLayers.smoothedStretches(RideLayers.speedStretches(pts))
        let pieces = RoutePieces.pieces(stretches, ramp: LayerRamps.speed(colourBlind: false))
        expect(!pieces.isEmpty && pieces.count <= stretches.count, "\(stretches.count) stretches \u{2192} \(pieces.count) pieces")
        expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.coords.last == $1.coords.first }, "the pieces meet, no gaps")
        let colours = Set(pieces.map { "\(Int($0.r * 100))-\(Int($0.g * 100))" })
        expect(colours.count > 1, "the colour changes along the line (\(colours.count) shades)")
        expect(RoutePieces.width == 6 && GradientPath.pieceStyle().lineCap == .butt, "6 pt, butt caps (lab B)")
        expect.report("u168")
    }
}
