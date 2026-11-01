import CorckieCore
import Foundation

/// Batch 102.011126.00 checks, on made-up input only (nothing real is read or written).
/// u168 the route line is short solid pieces of the lab's B width (R1 / note 17),
/// u166 the Battery layer marks each first drop below 10 % steps (R2),
/// u169 Home's last reading with its time and the labelled charge target (R3 / B64).
@MainActor
enum B102Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runRoutePieces()
        runBatteryMarks()
        runLastReading()
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
