import CorckieCore
import Foundation

/// Batch 101.251026.00 chunks C-E checks, on made-up input only (nothing real is read or written):
/// u147 the shared energy track: power shape scaled to the battery drop, battery-only fallback, gaps (F-34),
/// u148 the map layer row: five buttons, tap again for the derived view, stops as dots, honest legends (F-33),
/// u149 the route is one gradient line per unbroken run, nothing overlapping (B59),
/// u150 the ride summary's map takes ~55 % of the screen, the tiles sit in the lower part (B52),
/// u151 the route draws itself smoothly: eased, by distance, small steps per frame (B53),
/// u152 the ride review card snaps to full / default / one line / hidden with a lip (note 11).
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
