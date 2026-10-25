import XCTest
@testable import CorckieCore

/// Places hold to drag: the saved order, a drag, and places the order does not know. Made-up ids.
final class PlaceOrderTests: XCTestCase {
    func test_savedOrderFirst_newPlacesAfter_deletedOnesDropped() {
        XCTAssertEqual(PlaceOrder.apply(["a", "b", "c", "d"], saved: ["c", "gone", "a"]), ["c", "a", "b", "d"])
        XCTAssertEqual(PlaceOrder.apply(["a", "b"], saved: []), ["a", "b"])
        XCTAssertEqual(PlaceOrder.apply(["a", "b"], saved: ["b", "b"]), ["b", "a"], "a doubled id counts once")
    }

    func test_dragMovesLikeTheList() {
        XCTAssertEqual(PlaceOrder.moved(["a", "b", "c", "d"], from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(PlaceOrder.moved(["a", "b", "c", "d"], from: IndexSet(integer: 3), to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(PlaceOrder.moved(["a", "b", "c"], from: IndexSet(integer: 1), to: 1), ["a", "b", "c"], "dropped where it was")
        XCTAssertEqual(PlaceOrder.moved(["a", "b", "c"], from: IndexSet(integer: 0), to: 3), ["b", "c", "a"])
    }

    func test_storedAsJson() {
        XCTAssertEqual(PlaceOrder.parse(PlaceOrder.json(["x", "y"])), ["x", "y"])
        XCTAssertEqual(PlaceOrder.parse(nil), [])
        XCTAssertEqual(PlaceOrder.parse("not json"), [])
    }
}
