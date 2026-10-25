import CorckieCore
import Foundation

/// Batch 101.251026.00 chunks C-E checks, on made-up input only (nothing real is read or written):
/// u147 the shared energy track: power shape scaled to the battery drop, battery-only fallback, gaps (F-34),
/// u148 the map layer row: five buttons, tap again for the derived view, stops as dots, honest legends (F-33),
/// u149 the route is one gradient line per unbroken run, nothing overlapping (B59).
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
