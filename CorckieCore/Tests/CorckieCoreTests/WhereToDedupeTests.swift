import XCTest
@testable import CorckieCore

/// B61: "Home" twice in Where to?. Made-up places only (a grid near 10 N 20 E, no real spot).
final class WhereToDedupeTests: XCTestCase {
    private let home = WhereToDedupe.NamedPlace(id: "home", name: "Home", center: GeoPoint(lat: 10, lon: 20), radiusM: nil)
    private let uni = WhereToDedupe.NamedPlace(id: "uni", name: "Uni", center: GeoPoint(lat: 10.05, lon: 20), radiusM: 300)
    private var places: [WhereToDedupe.NamedPlace] { [home, uni] }

    func test_B61_layer1_aRouteEndingInsideHome_isLinkedToHome() {
        let end = GeoPoint(lat: 10.0009, lon: 20)        // ~100 m from Home's centre, inside its automatic 200 m
        XCTAssertEqual(WhereToDedupe.placeContaining(end, places: places), "home")
        XCTAssertEqual(WhereToDedupe.relink(toPlaceId: "unnamed-7", end: end, places: places), "home", "linked to an unnamed spot: moved to Home")
        XCTAssertNil(WhereToDedupe.relink(toPlaceId: "home", end: end, places: places), "already right: left alone")
        XCTAssertNil(WhereToDedupe.relink(toPlaceId: "x", end: GeoPoint(lat: 10.02, lon: 20), places: places), "ends in no place: left alone")
    }

    func test_B61_endPlace_byCircle_thenLink_thenName() {
        XCTAssertEqual(WhereToDedupe.endPlace(toPlaceId: nil, end: GeoPoint(lat: 10.0501, lon: 20), label: "Somewhere", places: places), "uni")
        XCTAssertEqual(WhereToDedupe.endPlace(toPlaceId: "uni", end: nil, label: "x", places: places), "uni")
        XCTAssertEqual(WhereToDedupe.endPlace(toPlaceId: "unnamed", end: nil, label: " home", places: places), "home", "same name, other case and spaces")
        XCTAssertNil(WhereToDedupe.endPlace(toPlaceId: "unnamed", end: GeoPoint(lat: 10.02, lon: 20), label: "Gym", places: places))
    }

    func test_B61_overlappingCircles_nearestCentreWins() {
        let near = WhereToDedupe.NamedPlace(id: "cafe", name: "Cafe", center: GeoPoint(lat: 10.0015, lon: 20), radiusM: 200)
        XCTAssertEqual(WhereToDedupe.placeContaining(GeoPoint(lat: 10.0013, lon: 20), places: [home, near]), "cafe")
    }

    func test_B61_layer3_duplicatesAreNamed_sameSpotOrSameName() {
        let rows = [WhereToDedupe.Row(key: "r1", name: "Home", placeId: "home"),
                    WhereToDedupe.Row(key: "r2", name: "Home", placeId: nil),
                    WhereToDedupe.Row(key: "place:uni", name: "Uni", placeId: "uni"),
                    WhereToDedupe.Row(key: "r3", name: "Campus", placeId: "uni")]
        XCTAssertEqual(WhereToDedupe.duplicates(rows), ["Home twice: same name", "Uni twice: same place"])
        XCTAssertEqual(WhereToDedupe.duplicates([rows[0], rows[2]]), [])
    }

    func test_B61_layer2_keepOnePerName_prefersThePlaceRow() {
        let rows = [WhereToDedupe.Row(key: "r2", name: "Home", placeId: nil),
                    WhereToDedupe.Row(key: "r9", name: "Work", placeId: nil),
                    WhereToDedupe.Row(key: "place:home", name: "home", placeId: "home")]
        let kept = WhereToDedupe.keepOnePerName(rows)
        XCTAssertEqual(kept.map(\.key), ["place:home", "r9"], "the place row replaces the grey route row in its position")
        XCTAssertEqual(WhereToDedupe.duplicates(kept), [])
    }
}
