import XCTest
@testable import CorckieCore

/// Note 18: Circle (default) or Outline per place; the outline replaces the circle; rides that stay inside are "Around" rides.
final class PlaceOutlineTests: XCTestCase {
    /// A made-up 400 m × 200 m campus (not round) near 10° N 20° E
    private let o = GeoPoint(lat: 10, lon: 20)
    private func at(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(lat: o.lat + y / 111_320, lon: o.lon + x / (111_320 * cos(o.lat * .pi / 180)))
    }
    private var campus: [GeoPoint] { [at(0, 0), at(400, 0), at(400, 200), at(0, 200)] }

    func testInsideAndOutside() {
        XCTAssertTrue(PlaceOutline.contains(campus, at(350, 100)), "far corner of the long side is inside")
        XCTAssertFalse(PlaceOutline.contains(campus, at(200, 260)), "60 m beyond the short side is outside")
        XCTAssertTrue(PlaceOutline.contains(campus, at(400, 100)), "the edge counts as inside")
        XCTAssertFalse(PlaceOutline.contains(Array(campus.prefix(2)), at(10, 0)), "two points are no outline")
    }

    func testAreaAndWords() {
        XCTAssertEqual(PlaceOutline.areaM2(campus), 80_000, accuracy: 50)
        XCTAssertEqual(PlaceOutline.areaText(80_000), "8.0 ha")
        XCTAssertEqual(PlaceOutline.areaText(853), "850 m\u{00B2}")
        XCTAssertEqual(PlaceOutline.areaText(2_300_000), "2.3 km\u{00B2}")
    }

    func testStoredAsJson() {
        let back = PlaceOutline.parse(PlaceOutline.json(campus))
        XCTAssertEqual(back?.count, 4)
        XCTAssertNil(PlaceOutline.parse("[]"))
        XCTAssertNil(PlaceOutline.parse(nil))
        XCTAssertEqual(PlaceOutline.key(placeId: "uni"), "place.outline.uni")
    }

    func testTheOutlineReplacesTheCircle() {
        let centre = PlaceOutline.centre(campus)!
        // a 100 m circle misses the far end of the campus, the outline does not; and the outline refuses a point the circle takes
        let circle = PlaceInfo(id: "uni", name: "Uni", point: centre, radiusM: 100)
        let drawn = PlaceInfo(id: "uni", name: "Uni", point: centre, radiusM: 100, outline: campus)
        XCTAssertFalse(PlaceMatcher.reaches(circle, at(390, 100), tripLengthM: 5_000))
        XCTAssertTrue(PlaceMatcher.reaches(drawn, at(390, 100), tripLengthM: 5_000))
        XCTAssertTrue(PlaceMatcher.reaches(circle, at(200, 190), tripLengthM: 5_000))
        XCTAssertFalse(PlaceMatcher.reaches(drawn, at(200, 210), tripLengthM: 5_000))
        XCTAssertTrue(PlaceHere.isHere(phone: at(390, 100), place: centre, radiusM: 100, outline: campus))
        XCTAssertFalse(PlaceHere.isHere(phone: at(390, 100), place: centre, radiusM: 100))
        let named = WhereToDedupe.NamedPlace(id: "uni", name: "Uni", center: centre, radiusM: 100, outline: campus)
        XCTAssertEqual(WhereToDedupe.placeContaining(at(390, 100), places: [named]), "uni")
        XCTAssertNil(WhereToDedupe.placeContaining(at(200, 260), places: [named]))
    }

    func testARideThatStaysInsideIsAroundTheOutlinePlace() {
        let centre = PlaceOutline.centre(campus)!
        var book = RouteBook(places: [PlaceInfo(id: "uni", name: "Uni", point: centre, outline: campus)])
        let inside: [GeoPoint] = (0...30).map { (k: Int) -> GeoPoint in
            let x: Double = 20 + Double(k) * 12
            let y: Double = 50 + Double(k % 5) * 20
            return at(x, y)
        }
        let around = RoutedRide(id: "a", startAt: 0, distanceM: 1_200, shape: TripShape(start: inside.first, end: inside.last, path: inside))
        let u = book.ingest(around, pool: [])
        XCTAssertEqual(u.assignments.first?.outcome, .around)
        XCTAssertNil(u.assignments.first?.routeId)
        // out and back again (a loop that leaves the outline) is not "around"
        var loop: [GeoPoint] = [at(200, 100)]
        for k in 1...20 { loop.append(at(200, 200 + Double(k) * 100)) }
        for k in (1...20).reversed() { loop.append(at(210, 200 + Double(k) * 100)) }
        loop.append(at(200, 100))
        let ride = RoutedRide(id: "b", startAt: 0, distanceM: 4_000, shape: TripShape(start: loop.first, end: loop.last, path: loop))
        XCTAssertNotEqual(book.ingest(ride, pool: []).assignments.first?.outcome, .around)
        // a circle place never makes "around" rides
        var circles = RouteBook(places: [PlaceInfo(id: "home", name: "Home", point: centre, radiusM: 300)])
        XCTAssertNotEqual(circles.ingest(around, pool: []).assignments.first?.outcome, .around)
    }

    func testTheEditor() {
        var e = OutlineEditor()
        XCTAssertNil(e.areaLine)
        e.add(at(0, 0)); e.add(at(400, 0))
        XCTAssertEqual(e.midpoints.count, 1, "two points: one handle")
        e.add(at(400, 200))
        XCTAssertTrue(e.isValid)
        XCTAssertEqual(e.midpoints.count, 3, "closed: a handle on every edge")
        e.insertMidpoint(after: 2)   // between (400,200) and (0,0)
        XCTAssertEqual(e.points.count, 4)
        e.move(3, to: at(0, 200))
        XCTAssertEqual(e.areaLine, "Area 8.0 ha")
        e.undo()
        XCTAssertNotEqual(e.points[3], at(0, 200), "undo takes back the drag")
        e.reset()
        XCTAssertTrue(e.points.isEmpty)
        e.undo()
        XCTAssertEqual(e.points.count, 4, "undo brings the points back after reset")
        XCTAssertTrue(e.changed)
    }
}
