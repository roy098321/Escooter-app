import CorckieCore
import Foundation

/// Batch 11 check u203, on made-up data only: the G500 is found and named, the Garage rules (auto-add, active = connected,
/// Sold / Lost / Remove keep everything, legacy rides by time, the name on the lock screen only with 2+, Stats filter), the tyre-pressure
/// hint (quiet on normal rides and while learning, creep -> tyre, jump -> brake / wheel, cold ruled out). The real data is never touched.
@MainActor
enum B111Checks {
    typealias Expect = B101LateChecks.Expect

    private static func ride(_ i: Int, _ whKm: Double, temp: Double = 20) -> EnergyRide {
        let n = [0, 0.02, -0.02, 0.01, -0.01, 0.03, -0.03][i % 7]
        return EnergyRide(rideId: "lab\(i)", day: i, routeId: "LAB", distanceKm: 6, energyWh: whKm * 6 * (1 + n), airTempC: temp,
                          headwindKmh: 5, avgKmh: 18, stopsPerKm: 1, mainGear: 3, wheelOverGps: 1, pull: 100, motorRiseC: 15, firmware: "1")
    }

    static func run() {
        let expect = Expect()
        // N11-5
        expect(ScooterGatt.isScooter(name: "G500", manufacturerData: []) && !ScooterGatt.isScooter(name: "G5000", manufacturerData: []),
               "G500 found, unknown names ignored")
        expect(KnownScooters.modelName(advertisedName: "G500", makerTagged: false) == "RND G500", "named RND G500")
        // N11-2
        var g = GarageRegistry()
        g = g.connected(id: "A", model: "RND G100", atMs: 1).0
        expect(g.lockScreenName(activeId: "A") == "Scooter" && !g.showsGarage, "one scooter: looks as before")
        g = g.connected(id: "B", model: "RND G500", atMs: 2).0
        expect(g.active(connectedId: nil)?.id == "B" && g.showsGarage && g.lockScreenName(activeId: "B") == "RND G500",
               "a new scooter is added and named; 2+: Garage and the name on the lock screen")
        g = g.retire("A", as: .sold, atMs: 3)
        expect(g.scooters.count == 2 && g.inUse.map(\.id) == ["B"] && g.scooter("A")?.status.label == "Sold", "Sold keeps it, read-only")
        expect(GarageLegacy.assign(rideStartsMs: ["x": 1, "y": 5], scooters: [(id: "A", firstSeenMs: 0), (id: "B", firstSeenMs: 4)]) == ["x": "A", "y": "B"],
               "old rides go to the scooter in use then")
        expect(GarageStatsFilter.options(g).first == .all, "Stats: all scooters by default")
        // N11-1
        var book = EnergyBook()
        var quiet = true
        for i in 0..<40 {
            let out = EnergyHint.ride(&book, scooterId: "LAB", ride(i, 20), packWh: 500)
            if out.stepAfter != .quiet { quiet = false }
        }
        expect(quiet, "40 normal rides: no hint")
        var cold = book
        for i in 40..<43 { _ = EnergyHint.ride(&cold, scooterId: "LAB", ride(i, 28, temp: 2), packWh: 500) }
        expect(cold.scooters["LAB"]?.step == .quiet, "cold rides use more: ruled out")
        var creep = book
        for k in 1...12 { _ = EnergyHint.ride(&creep, scooterId: "LAB", ride(40 + k, 20 * (1 + 0.025 * Double(k))), packWh: 500) }
        expect(creep.scooters["LAB"]?.step != .quiet, "a slow creep is caught")
        var jump = book
        _ = EnergyHint.ride(&jump, scooterId: "LAB", ride(41, 27), packWh: 500)
        _ = EnergyHint.ride(&jump, scooterId: "LAB", ride(42, 27), packWh: 500)
        expect(jump.scooters["LAB"]?.step == .brakeWheel, "a sudden jump: lift the wheel and spin it")
        expect.report("u203")
    }
}
