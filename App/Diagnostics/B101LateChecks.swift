import CorckieCore
import Foundation

/// Batch 101.251026.00 chunks C-E checks, on made-up input only (nothing real is read or written):
/// u147 the shared energy track: power shape scaled to the battery drop, battery-only fallback, gaps (F-34),
/// u148 the map layer row: five buttons, tap again for the derived view, stops as dots, honest legends (F-33),
/// u149 the route is one gradient line per unbroken run, nothing overlapping (B59),
/// u150 the ride summary's map takes ~55 % of the screen, the tiles sit in the lower part (B52),
/// u151 the route draws itself smoothly: eased, by distance, small steps per frame (B53),
/// u152 the ride review card snaps to full / default / one line / hidden with a lip (note 11),
/// u153 Plug in after every ride: when it shows, − / +, the alert time with its margin, why it is estimated (F-31b),
/// u154 one Stats chart: title, metric switch, reference lines, a readout per bar (note 8),
/// u155 insights show progress with early read / confident marks, a shrinking range, pages once confident (note 9),
/// u156 the ride graph: Speed by default, chips with own scales and derived lines, map ↔ chart, hills move the window (note 13, hotfix 01).
@MainActor
enum B101LateChecks {
    final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
        func report(_ id: String) { CheckResults.shared.set(id, ok ? .pass : .fail, line) }
    }

    static func run() {
        runEnergyTrack()
        runLayerRow()
        runGradientLine()
        runSummaryLayout()
        runSmoothDraw()
        runRideCard()
        runPlugIn()
        runStatsChart()
        runInsightProgress()
        runRideGraph()
        runReleaseName()
        runWhatsNew()
        runPlaceOrder()
    }

    // MARK: u144

    /// Places hold-to-drag (batch 101 chunk B): a drag saves the new order, the saved order sorts the list, unknown places keep their order
    private static func runPlaceOrder() {
        let expect = Expect()
        let ids = ["home", "uni", "gym", "grandma"]
        let moved = PlaceOrder.moved(ids, from: IndexSet(integer: 3), to: 0)
        expect(moved == ["grandma", "home", "uni", "gym"], "drag Grandma to the top: " + moved.joined(separator: ", "))
        let saved = PlaceOrder.parse(PlaceOrder.json(moved))
        expect(saved == moved, "the order is saved and read back")
        expect(PlaceOrder.apply(ids + ["new"], saved: saved) == moved + ["new"], "a new place goes after the ordered ones")
        expect(PlaceOrder.apply(["home", "uni"], saved: saved) == ["home", "uni"], "a removed place is skipped")
        expect.report("u144")
    }

    // MARK: u157

    /// F-32: this build's entry is bundled; the card shows once, never during a ride
    private static func runWhatsNew() {
        let expect = Expect()
        let entries = WhatsNewStore.entries
        let mine = WhatsNew.entry(for: AppInfo.releaseName, in: entries)
        expect(mine != nil, "bundled entry for \(AppInfo.releaseName): \(mine?.title ?? "missing")")
        expect((3...4).contains(mine?.items.count ?? 0) && !(mine?.full.isEmpty ?? true), "\(mine?.items.count ?? 0) items, \(mine?.full.count ?? 0) lines in the full list")
        let v = AppInfo.releaseName
        expect(WhatsNew.shouldShow(current: v, lastSeen: "100.000000.00", riding: false, entries: entries)
               && !WhatsNew.shouldShow(current: v, lastSeen: "100.000000.00", riding: true, entries: entries)
               && !WhatsNew.shouldShow(current: v, lastSeen: v, riding: false, entries: entries), "once per build, never during a ride")
        expect.report("u157")
    }

    // MARK: u158

    /// F-30b: this build carries its release name, and the report zip / IPA use it
    private static func runReleaseName() {
        let expect = Expect()
        expect(ReleaseName.isValid(AppInfo.releaseName), "this build: \(AppInfo.releaseName) (build \(AppInfo.build))")
        expect(AppInfo.releaseCode.count == 6, "What's new code: \(AppInfo.releaseCode)")
        expect(ReleaseName.fileStem(AppInfo.releaseName).hasPrefix("CorckieApp-1"), "IPA name: \(ReleaseName.fileStem(AppInfo.releaseName)).ipa")
        expect.report("u158")
    }

    // MARK: u156

    /// Note 13: a made-up ride with a climb: the chips, incline on the hill, the map tap's time, the hill selection, the link words
    private static func runRideGraph() {
        let expect = Expect()
        let pts = madeUpRide(400, power: { (100..<250).contains($0) ? 700 : 250 }, battery: { 80 - $0 / 50 },
                             alt: { $0 < 100 ? 10 : ($0 < 250 ? 10 + Double($0 - 100) * 0.2 : 40) },
                             speed: { (100..<250).contains($0) ? 12 + Double($0 % 7) : 25 + Double($0 % 5) })
        let data = RideLayerData(points: pts, energy: EnergyTrack.build(pts), weather: [], rideStartMs: 0)
        expect(GraphSeries.defaultChips == [.speed], "Speed is the only line at first")
        let chips = RideGraph.available(data)
        expect(chips.contains(.incline) && chips.contains(.accel) && chips.contains(.batteryPerKm), "chips: " + chips.map(\.title).joined(separator: ", "))
        var picks = GraphChips(available: chips)
        picks.tap(.speed)
        expect(picks.label(.speed) == "Speed \u{2192} Accel" && picks.highlightedSeries == .accel, "tap Speed again: " + picks.label(.speed))
        let incline = RideGraph.line(.incline, data).value(at: 175) ?? 0
        expect(abs(incline - 4) < 0.6, String(format: "incline on the hill %.1f %%", incline))
        let tapped = pts[200].lat.flatMap { lat in pts[200].lon.map { GeoPoint(lat: lat, lon: $0) } }.flatMap { RideGraph.time(near: $0, points: pts) }
        expect(tapped == 200, "a map tap on the route moves the cursor to its moment")
        let hills = RideGraph.hills(pts, energy: data.energy)
        expect(hills.count == 1 && RideGraph.hill(at: 175, hills: hills) != nil, "the hill can be selected: " + (hills.first?.name ?? "none"))
        let window = RideGraph.window(for: hills.first ?? GraphSelection(from: 0, to: 400), full: 0...399)
        let lit = RideGraph.window(window, points: pts).count
        expect(lit > 0 && lit < pts.count, "Hills puts the window on the climb: \(lit) of \(pts.count) map points coloured")
        expect.report("u156")
    }

    // MARK: u155

    /// Note 9: a learning insight counts to its first read, an early read shows a range, a confident one is a page
    private static func runInsightProgress() {
        let expect = Expect()
        let learning = InsightProgressBuilder.make([.learning(.sweetSpot, "5 of 12 steady stretches")]).progress.first
        expect(learning?.countLine == "5 of 12 steady stretches to a first read", "learning: \(learning?.countLine ?? "nothing")")
        expect(InsightProgressBuilder.range("Sweet spot between 26 and 30 km/h.")?.text == "26\u{2013}30 km/h", "the early read's range: 26\u{2013}30 km/h")
        let samples = InsightProgressBuilder.make(InsightSamplesF21.outcomes())
        expect(samples.progress.filter { $0.stage == .early }.allSatisfy { $0.range != nil && $0.card != nil },
               "made-up insights: \(samples.progress.count) on their way, \(samples.pages.count) page(s): " + samples.pages.map(\.page.rawValue).joined(separator: ", "))
        expect(samples.pages.allSatisfy { $0.card.certainty.level == .high }, "only confident insights become pages")
        expect.report("u155")
    }

    // MARK: u154

    /// Note 8: one chart with km · rides · time · ₪ saved, "km per day", dashed reference lines, "13 Oct · 18 km"
    private static func runStatsChart() {
        let expect = Expect()
        let off = 0
        let day: Int64 = 86_400_000
        let p = StatsCalc.period(span: .week, mode: .calendar, nowMs: 1_791_158_400_000, utcOffsetMin: off, back: 1)   // a made-up finished week
        let start = p.startMs
        let prices = StatsPrices(packWh: 800, electricityIlsPerKwh: 0.64, fuelIlsByMonth: [:], fuelFallbackIls: 8, fuelLPer100km: 7)
        let rides = [StatsRide(startAt: start + 2 * day + 8 * 3_600_000, utcOffsetMin: off, kind: "ride", distanceM: 9_000, totalS: 1_200, usedPct: 10),
                     StatsRide(startAt: start + 2 * day + 17 * 3_600_000, utcOffsetMin: off, kind: "ride", distanceM: 9_000, totalS: 1_500, usedPct: 10)]
        let t = StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: off)
        let km = StatsChart.make(t, metric: .km, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        expect(km.title == "km per day" && km.bars.count == 7, "title \(km.title), \(km.bars.count) bars")
        expect(km.readout(2)?.hasSuffix("\u{00B7} 18 km") == true, "tap a bar: \(km.readout(2) ?? "nothing")")
        expect(km.references == [5, 10, 15], "dashed lines at " + km.references.map { StatsChart.valueText($0, .km) }.joined(separator: ", "))
        let rideBars = StatsChart.make(t, metric: .rides, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        let time = StatsChart.make(t, metric: .time, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        expect(rideBars.bars[2].value == 2 && abs(time.bars[2].value - 45) < 0.01, "the switch: 2 rides, 45 min on that day")
        expect.report("u154")
    }

    // MARK: u153

    /// F-31b: the pill after every ride (2 h, never during a ride, gone at the next connect), 100 % by default, alert time with margin
    private static func runPlugIn() {
        let expect = Expect()
        let end: Int64 = 1_790_000_000_000
        expect(PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: false, charging: false, connected: false, lastConnectMs: end - 600_000),
               "shows right after a ride")
        expect(!PlugIn.shows(rideEndMs: end, nowMs: end + 7_300_000, riding: false, charging: false, connected: false, lastConnectMs: nil)
               && !PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: true, charging: false, connected: false, lastConnectMs: nil)
               && !PlugIn.shows(rideEndMs: end, nowMs: end + 3_600_000, riding: false, charging: false, connected: false, lastConnectMs: end + 60_000),
               "gone after 2 h, during a ride and after the next connect")
        expect(PlugAlert.default.pillText == "100%" && PlugIn.stepped(.battery(100), by: -1) == .battery(95) && PlugIn.stepped(.range(15), by: 1) == .range(16),
               "100% by default; \u{2212} / + by 5 % or 1 km")
        let s = ChargeSession(startPct: 18, startMs: end, pctPerKm: 2.0, reservePct: 10, scooterName: "Test")
        expect(PlugIn.alertMs(s, .battery(100)) == ChargeModel.notifyFullMs(s), "100 %: the alert includes the +5 % margin")
        expect(PlugIn.why(s, .battery(100), utcOffsetMin: 0).contains("13.6 % an hour"), "estimated explains the charge rate")
        expect.report("u153")
    }

    // MARK: u152

    /// Note 11: four heights in order, the layer row stays visible at full height, a flick snaps to the nearest, the one line
    private static func runRideCard() {
        let expect = Expect()
        let h = 759.0, inset = 59.0, controls = 170.0, bar = 90.0
        let tops = Dictionary(uniqueKeysWithValues: CardDetent.allCases.map {
            ($0, RideCardLayout.top($0, height: h, topInset: inset, controlsBottom: controls, bottomReserve: bar))
        })
        let order = CardDetent.allCases.compactMap { tops[$0] }
        expect(order == order.sorted() && Set(order).count == 4, "full / default / one line / hidden in order: " + order.map { String(Int($0)) }.joined(separator: " \u{00B7} "))
        expect((tops[.full] ?? 0) > controls, "the map, layer row and legend stay visible at full height")
        expect(tops[.hidden] == h, "hidden leaves only the lip")
        expect(RideCardLayout.snap(predictedTop: h + 200, tops: tops) == .hidden && RideCardLayout.snap(predictedTop: 0, tops: tops) == .full,
               "a flick snaps to the nearest height")
        expect(RideCardLayout.line(time: "19 min", distance: "8.0 km", topSpeed: "32 km/h") == "19 min \u{00B7} 8.0 km \u{00B7} 32 km/h", "one line: 19 min \u{00B7} 8.0 km \u{00B7} 32 km/h")
        expect.report("u152")
    }

    // MARK: u151

    /// B53: the drawing front moves in small, even steps at 120 Hz (no jumps), ends exactly, a partial stretch at the front
    private static func runSmoothDraw() {
        let expect = Expect()
        var last = 0.0, biggest = 0.0
        for f in 1...120 {
            let p = RouteReveal.progress(elapsedS: Double(f) / 120)
            biggest = max(biggest, p - last)
            last = p
        }
        expect(biggest < 0.02 && last == 1, String(format: "largest step per 1/120 s frame %.3f of the route, ends at 100 %%", biggest))
        let shown = RouteReveal.visible(ends: [0.25, 0.5, 0.75, 1], progress: 0.6)
        expect(shown.whole == 2 && abs(shown.partial - 0.4) < 0.001, "the front stretch is drawn in part")
        expect.report("u151")
    }

    // MARK: u150

    /// B52: map ~55 % of the screen on the ride summary / detail, the scroll area keeps its room on small phones
    private static func runSummaryLayout() {
        let expect = Expect()
        for (name, h) in [("iPhone 15", 852.0), ("Pro Max", 932.0), ("SE", 667.0)] {
            let map = MapScreenLayout.rideMapHeight(screenHeight: h)
            expect(map / h >= 0.5 && map / h <= 0.56 && h - map >= MapScreenLayout.minScrollHeight,
                   String(format: "%@: map %.0f of %.0f pt (%.0f %%)", name, map, h, map / h * 100))
        }
        expect.report("u150")
    }

    // MARK: u149

    /// B59: one polyline per unbroken run, a colour stop per stretch along it
    private static func runGradientLine() {
        let expect = Expect()
        let pts = madeUpRide(300, power: { _ in 300 }, battery: { _ in 80 }, speed: { 10 + Double($0 % 60) / 2 })
        let stretches = RideLayers.smoothedStretches(RideLayers.speedStretches(pts))
        let runs = GradientLine.runs(stretches, ramp: LayerRamps.speed(colourBlind: false))
        expect(runs.count == 1, "\(stretches.count) stretches \u{2192} \(runs.count) line(s)")
        expect(runs.first?.coords.count == stretches.count + 1, "every point once, nothing overlapping")
        let locations = runs.first?.stops.map(\.location) ?? []
        expect(locations.first == 0 && locations.last == 1 && zip(locations, locations.dropFirst()).allSatisfy { $0 <= $1 },
               "\(locations.count) colour stops in order along the line")
        var broken = stretches
        if broken.count > 4 { broken.removeSubrange(2...3) }
        expect(GradientLine.runs(broken, ramp: LayerRamps.speed(colourBlind: false)).count == 2, "a gap in the fixes starts a second line")
        expect.report("u149")
    }

    // MARK: u148

    /// F-33: Speed · Hills · Wind · Battery · Temp; tap again → Steady · Grade · Wind cost · Drain · Heating; stops on Speed
    private static func runLayerRow() {
        let expect = Expect()
        let labels = MapLayer.allCases.map { LayerView($0).buttonLabel }
        expect(labels == ["Speed", "Hills", "Wind", "Battery", "Temp"], "the row: " + labels.joined(separator: " \u{00B7} "))
        let deep = MapLayer.allCases.map { LayerView($0).tapped($0).buttonLabel }
        expect(deep == ["Steady", "Grade", "Wind cost", "Drain", "Heating"], "tap again: " + deep.joined(separator: " \u{00B7} "))
        expect(LayerView(.temp).title == "Controller temp", "Temp is labelled as the controller's temperature")
        let pts = madeUpRide(400, power: { _ in 300 }, battery: { 80 - $0 / 40 }, alt: { 10 + Double($0) / 20 },
                             temp: { 30 + Double($0) / 30 }, speed: { (100..<190).contains($0) ? 0 : 18 })
        let data = RideLayerData(points: pts, energy: EnergyTrack.build(pts), weather: [], rideStartMs: 0)
        expect(LayerViews.available(data) == MapLayer.allCases, "a ride with every reading shows all five buttons")
        let empty = MapLayer.allCases.filter { $0 != .wind }.flatMap { [LayerView($0), LayerView($0, deep: true)] }
            .filter { LayerViews.stretches($0, data).isEmpty }.map(\.title)
        expect(empty.isEmpty, "every view draws" + (empty.isEmpty ? "" : ", empty: " + empty.joined(separator: ", ")))
        expect(LayerViews.stops(pts).count == 1, "one 90 s stop = one dot")
        expect(LayerViews.stretches(LayerView(.wind), data).isEmpty && LayerViews.emptyText(LayerView(.wind)).hasPrefix("No wind data yet"),
               "no weather yet: No wind data yet")
        expect.report("u148")
    }

    /// A made-up straight ride, one reading a second at 18 km/h (not a real place)
    static func madeUpRide(_ n: Int, power: (Int) -> Double?, battery: (Int) -> Int?, alt: ((Int) -> Double?)? = nil,
                           temp: ((Int) -> Double?)? = nil, speed: ((Int) -> Double)? = nil) -> [SeriesPoint] {
        (0..<n).map { i in
            SeriesPoint(t: Double(i), lat: 10.0 + Double(i) * 5 / 111_195, lon: 20.0, hAccM: 5, speedKmh: speed?(i) ?? 18,
                        batteryPct: battery(i), altM: alt?(i), powerW: power(i), tempC: temp?(i))
        }
    }

    // MARK: u147

    /// F-34: power shape per ~100 m, scaled so the ride total equals the battery drop
    private static func runEnergyTrack() {
        let expect = Expect()
        let pts = madeUpRide(601, power: { $0 < 300 ? 200 : 600 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 })
        let track = EnergyTrack.build(pts)
        let sum = track.bins.compactMap(\.usedPct).reduce(0, +)
        expect(track.source == .power && abs(sum - 10) < 0.05, String(format: "power shape adds up to the 10 %% drop (%.2f)", sum))
        let early = track.bins.first?.usedPct ?? 0, late = track.bins.last?.usedPct ?? 0
        expect(late > early * 2, "a stretch on more power costs more")
        let noPower = EnergyTrack.build(madeUpRide(601, power: { _ in nil }, battery: { $0 >= 590 ? 74 : 80 - $0 / 100 }))
        expect(noPower.source == .battery, "no power readings: the battery % alone")
        let gap = EnergyTrack.build(madeUpRide(601, power: { (200..<400).contains($0) ? nil : 300 }, battery: { $0 >= 590 ? 70 : 80 - $0 / 60 }))
        expect(gap.bin(at: 300)?.usedPct == nil, "the phone's stretch is a gap, not a guess")
        expect.report("u147")
    }
}
