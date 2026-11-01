import XCTest
@testable import CorckieCore

/// B66: a learned trip time only at the trip's start place; elsewhere the chip is just the name.
final class TripFromHereTests: XCTestCase {
    func testOnlyAtTheStartPlace() {
        XCTAssertTrue(TripFromHere.applies(tripStartPlaceId: "home", herePlaceId: "home"))
        XCTAssertFalse(TripFromHere.applies(tripStartPlaceId: "home", herePlaceId: "uni"))
        XCTAssertFalse(TripFromHere.applies(tripStartPlaceId: "home", herePlaceId: nil))
        XCTAssertFalse(TripFromHere.applies(tripStartPlaceId: nil, herePlaceId: "home"))
    }

    func testNameOnlyClearsEveryNumber() {
        var chip = WhereToChip(routeId: "r1", label: "Uni", detail: "Uni \u{00B7} about 29 min")
        chip.timeText = "29 min"; chip.arriveText = "08:10"; chip.timeS = 1_740; chip.usedText = "12%"; chip.usualNeedPct = 12; chip.note = "x"
        chip.nameOnly()
        XCTAssertNil(chip.timeText); XCTAssertNil(chip.arriveText); XCTAssertNil(chip.timeS)
        XCTAssertNil(chip.usedText); XCTAssertNil(chip.usualNeedPct); XCTAssertNil(chip.note)
        XCTAssertEqual(chip.detail, "Uni")
        XCTAssertEqual(QuickDial.summary(name: chip.label, minutes: nil, needPct: chip.usualNeedPct, note: chip.note), "Uni")
    }
}
