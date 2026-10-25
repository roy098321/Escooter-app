import XCTest
@testable import CorckieCore

/// F-36: the "Scooter on" notification's destination buttons; F-39 leftover: "↻ Continue to …" first. Made-up places only.
final class ScooterOnActionsTests: XCTestCase {
    private let places = [ScooterOnActions.Place(key: "r1", name: "Uni", placeId: "uni"),
                          ScooterOnActions.Place(key: "place:home", name: "Home", placeId: "home"),
                          ScooterOnActions.Place(key: "place:gran", name: "Grandma", placeId: "gran"),
                          ScooterOnActions.Place(key: "place:gym", name: "Gym", placeId: "gym")]

    func test_F36_theOwnersButtons_UniHomeGrandmaQuestionMark() {
        let a = ScooterOnActions.actions(continueTo: nil, places: places)
        XCTAssertEqual(a.map(\.title), ["Uni", "Home", "Grandma", "No destination"])
        XCTAssertEqual(a.count, ScooterOnActions.maxActions)
    }

    func test_F39_continueComesFirst_andItsPlaceIsNotRepeated() {
        let c = ScooterOnActions.Place(key: "place:uni", name: "Uni", placeId: "uni")
        let a = ScooterOnActions.actions(continueTo: c, places: places)
        XCTAssertEqual(a.map(\.title), ["\u{21BB} Continue to Uni", "Home", "Grandma", "No destination"])
        XCTAssertEqual(ScooterOnActions.choice(actionId: a[0].id), .continueTrip("place:uni"))
    }

    func test_F36_tappedButtonsMapBackToTheChoice() {
        let a = ScooterOnActions.actions(continueTo: nil, places: places)
        XCTAssertEqual(ScooterOnActions.choice(actionId: a[0].id), .destination("r1"))
        XCTAssertEqual(ScooterOnActions.choice(actionId: a[1].id), .destination("place:home"))
        XCTAssertEqual(ScooterOnActions.choice(actionId: a[3].id), .noDestination)
        XCTAssertNil(ScooterOnActions.choice(actionId: "com.apple.UNNotificationDefaultActionIdentifier"), "a plain tap is not a button")
        XCTAssertNil(ScooterOnActions.choice(actionId: "dest:"))
    }

    func test_F36_noPlaces_onlyNoDestination_andUnnamedPlacesAreLeftOut() {
        XCTAssertEqual(ScooterOnActions.actions(continueTo: nil, places: []).map(\.title), ["No destination"])
        let a = ScooterOnActions.actions(continueTo: nil, places: [ScooterOnActions.Place(key: "place:x", name: "")])
        XCTAssertEqual(a.map(\.title), ["No destination"])
    }
}
