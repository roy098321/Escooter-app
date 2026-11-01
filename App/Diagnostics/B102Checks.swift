import CorckieCore
import Foundation

/// Batch 102.011126.00 checks, on made-up input only (nothing real is read or written).
/// u168 the route line is short solid pieces of the lab's B width (R1 / note 17).
@MainActor
enum B102Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runRoutePieces()
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
