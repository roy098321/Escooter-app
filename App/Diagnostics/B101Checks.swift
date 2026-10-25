import CorckieCore
import Foundation

/// Batch 101.251026.00 chunk A checks ("never lose a ride"), on made-up input only (nothing real is read or written):
/// u130 the battery % flip filter and its per-scooter auto-detect (B56, B56b).
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
