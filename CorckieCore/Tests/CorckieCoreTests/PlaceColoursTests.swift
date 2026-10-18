import XCTest
@testable import CorckieCore

final class PlaceColoursTests: XCTestCase {
    func test_homeIsGreenWorkIsBlue() {
        let r = PlaceColours.assign(places: [("a", "Work"), ("b", "Home")], existing: [:])
        XCTAssertEqual(r["a"], "blue")
        XCTAssertEqual(r["b"], "green")
    }

    func test_othersTakeTheNextUnusedColourInOrder() {
        let r = PlaceColours.assign(places: [("a", nil), ("b", "Gym"), ("c", "")], existing: [:])
        XCTAssertEqual([r["a"], r["b"], r["c"]], ["orange", "pink", "vermillion"])
    }

    func test_existingColoursAreKeptAndNotReused() {
        let r = PlaceColours.assign(places: [("a", nil), ("b", nil)], existing: ["a": "orange"])
        XCTAssertNil(r["a"])
        XCTAssertEqual(r["b"], "pink")
    }

    func test_homeWhenGreenIsTakenFallsBackToNext() {
        let r = PlaceColours.assign(places: [("h", "Home")], existing: ["x": "green"])
        XCTAssertEqual(r["h"], "orange")
    }

    func test_runningOutStartsAgain() {
        let existing = Dictionary(uniqueKeysWithValues: PlaceColours.all.enumerated().map { ("p\($0.offset)", $0.element.id) })
        let r = PlaceColours.assign(places: [("n", nil)], existing: existing)
        XCTAssertTrue(PlaceColours.isValid(r["n"] ?? ""))
    }

    func test_hexOfUnknownIsGrey() {
        XCTAssertEqual(PlaceColours.hex(nil), PlaceColours.greyHex)
        XCTAssertEqual(PlaceColours.hex("green"), "#009E73")
        XCTAssertEqual(Set(PlaceColours.all.map(\.id)).count, PlaceColours.all.count)
    }
}
