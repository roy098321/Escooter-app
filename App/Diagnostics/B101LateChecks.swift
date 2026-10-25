import CorckieCore
import Foundation

/// Batch 101.251026.00 chunks C-E checks, on made-up input only (nothing real is read or written):
/// u147 the shared energy track: power shape scaled to the battery drop, battery-only fallback, gaps (F-34).
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
