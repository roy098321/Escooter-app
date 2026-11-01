import XCTest
@testable import CorckieCore

/// R1 / note 17: ride maps draw short solid pieces (lab option B); same-colour neighbours join into one piece.
final class RoutePiecesTests: XCTestCase {
    private func p(_ i: Int) -> GeoPoint { GeoPoint(lat: 10.0 + Double(i) * 0.000_3, lon: 20.0) }
    private let ramp = LayerRamps.speed(colourBlind: false)

    func testSameColourJoinsIntoOnePiece() {
        let stretches = (0..<10).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: 25) }
        let pieces = RoutePieces.pieces(stretches, ramp: ramp)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].coords.count, 11)
    }

    func testColourChangesAlongTheLine() {
        let stretches = (0..<10).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: Double($0) * 5) }
        let pieces = RoutePieces.pieces(stretches, ramp: ramp)
        XCTAssertEqual(pieces.count, 10, "every 5 km/h is a new colour step")
        XCTAssertGreaterThan(pieces[0].g, pieces[0].r, "slow = green")
        XCTAssertGreaterThan(pieces[9].r, pieces[9].g, "fast = red-ish")
        for k in 1..<pieces.count { XCTAssertEqual(pieces[k].coords.first, pieces[k - 1].coords.last, "pieces meet, no gap") }
    }

    func testABreakStartsANewPieceAndStillStretchesAreSkipped() {
        var stretches = (0..<3).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: 20) }
        stretches.append(ValueStretch(a: p(3), b: p(3), t: 3, value: 20))
        stretches += (10..<13).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: 20) }
        let pieces = RoutePieces.pieces(stretches, ramp: ramp)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(RoutePieces.pieces([], ramp: ramp), [])
    }

    func testWidthIsTheLabsB() {
        XCTAssertEqual(RoutePieces.width, 6)
    }
}
