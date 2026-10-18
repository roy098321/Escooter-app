import CorckieCore
import CorckieSim
import Foundation

/// P6-1 chunk 3 checks on made-up data in temporary databases: u58 place colours (F-08), u59 places by hand and the start / end labels (F-13 / F-06),
/// u60 the street lookup of the place map keeps to rounded coordinates and the cache (F-06 / P-2).
enum P61PlaceChecks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " · ") }
    }

    private static let base: Int64 = 1_790_000_000_000
    private static let day: Int64 = 86_400_000

    static func run() async {
        runColours()
        runByHand()
        await runStreet()
    }

    // MARK: u58

    private static func runColours() {
        let expect = Expect()
        let named = PlaceColours.assign(places: [(id: "a", name: "Work"), (id: "b", name: "Home"), (id: "c", name: nil), (id: "d", name: nil)], existing: [:])
        expect(named["b"] == "green" && named["a"] == "blue" && named["c"] == "orange" && named["d"] == "pink", "Home green, Work blue, then the next colours in order")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            for (id, name) in [("p1", "Home"), ("p2", nil), ("p3", "Work")] as [(String, String?)] {
                try store.save(place: PlaceRecord(id: id, name: name, lat: 40, lon: -75, radiusM: nil, canCharge: false, learnedAltM: nil, createdAt: base))
            }
            let first = PlaceColourStore.colours(database: temp)
            expect(first.count == 3 && Set(first.values).count == 3, "every place gets its own colour")
            try PlaceColourStore.write(placeId: "p2", colourId: "sky", database: temp)
            let again = PlaceColourStore.colours(database: temp)
            expect(again["p1"] == first["p1"] && again["p3"] == first["p3"] && again["p2"] == "sky", "stored per place and editable; the others stay")
            expect((try? RideQueries(temp).setting(key: "place.colour.p2")) != nil, "kept as the setting place.colour.<id>, no schema change")
        } catch {
            expect(false, "temporary database: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u58", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u59

    private static func runByHand() {
        let expect = Expect()
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            let id = try PlaceAddService.add(name: " Gym ", lat: 40.001, lon: -75.002, radiusM: 300, colourId: "pink", database: temp)
            let saved = try store.place(id: id)
            expect(saved?.name == "Gym" && saved?.radiusM == 300 && saved?.lat == 40.001 && saved?.canCharge == false, "a pin, name and circle size become a place in the same table")
            let item = PlaceMapLoader.item(placeId: id, database: temp)
            expect(item?.colourId == "pink" && item?.row.title == "Gym" && item?.circleM == 300, "its colour and circle show on the map screen")
            let unnamed = try PlaceAddService.add(name: "  ", lat: 40.1, lon: -75.1, radiusM: nil, colourId: "sky", database: temp)
            expect(try store.place(id: unnamed)?.name == nil && PlaceMapLoader.item(placeId: unnamed, database: temp)?.circleM == PlaceMapItem.automaticCircleM, "no name keeps it unnamed, automatic circle")
            try PlaceService.setRadius(placeId: id, radiusM: nil, database: temp)
            try PlaceService.setCanCharge(placeId: id, canCharge: true, database: temp)
            expect(try store.place(id: id)?.radiusM == nil && PlaceMapLoader.item(placeId: id, database: temp)?.row.canCharge == true, "circle and charging can be changed afterwards")
        } catch {
            expect(false, "place by hand: \(error.localizedDescription)")
        }
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            var routeId: String?
            for (id, k) in [("a", 0.0), ("b", 1.0)] {
                try RouteFixtures.insertRide(temp, id: id, path: SyntheticRoutes.main, startAt: base + Int64(k * Double(day)))
                routeId = try RouteProcessor.process(rideId: id, database: temp)?.routeId ?? routeId
            }
            let pins = routeId.map { PlaceMapLoader.pins(routeId: $0, database: temp) } ?? []
            expect(pins.count == 2 && pins.allSatisfy { PlaceColours.isValid($0.colourId) && !$0.name.isEmpty }, "route map: start and end place, each with a name and a colour")
            let ridePins = PlaceMapLoader.pins(rideId: "b", database: temp)
            expect(ridePins.count == 2 && ridePins[0].id != ridePins[1].id, "ride map: start and end place")
            let ends = try store.endPlaceIds()
            let colours = PlaceColourStore.colours(database: temp)
            expect(ends["b"] != nil && colours[ends["b"] ?? ""] != nil, "Rides list: a ride that ended at a place has its colour")
        } catch {
            expect(false, "ride labels: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u59", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u60

    private static func runStreet() async {
        let expect = Expect()
        let exact = GeoPoint(lat: 40.123456, lon: -75.654321)
        let r = StreetNaming.rounded(exact)
        expect(r.lat == 40.123 && r.lon == -75.654, "only coordinates rounded to 3 decimals (about 100 m) are looked up")
        expect(StreetNaming.cacheKey(exact) == StreetNaming.cacheKey(GeoPoint(lat: 40.1234, lon: -75.6543)), "nearby points share one cache entry, so a street is asked once")
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try RideQueries(temp).setSetting(key: StreetNaming.cacheKey(exact), json: "\"Example Street\"")
            // the cached answer comes back without asking the phone's geocoder
            let answer = await RouteNaming.shared.street(at: exact, database: temp)
            expect(answer.street == "Example Street" && answer.answered, "a street asked before comes from the cache")
        } catch {
            expect(false, "temporary database: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u60", expect.ok ? .pass : .fail, expect.line)
    }
}
