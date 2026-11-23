import CorckieCore
import Foundation
import XCTest

/// Batch 11 guard tests (N11-1 tyre hint, N11-2 Garage, N11-3 B100 logo ring, N11-4 thank-you, N11-5 B101 G500).
/// Logic in CorckieCore, plus checks on the app's source text and assets (Linux CI cannot build the app).
final class Batch111Tests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: N11-3 · B100 white ring around the Home logo

    /// RGBA pixels of a PNG written by Tools/b100_headermark.py (zlib stored blocks, so no inflate is needed on Linux).
    private func storedPNG(_ url: URL) throws -> (w: Int, h: Int, px: [UInt8]) {
        let d = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }
        var i = 8, w = 0, h = 0
        var z: [UInt8] = []
        while i + 8 <= d.count {
            let len = u32(i), type = String(bytes: d[i + 4..<i + 8], encoding: .ascii) ?? ""
            if type == "IHDR" {
                w = u32(i + 8); h = u32(i + 12)
                XCTAssertEqual(d[i + 16], 8, "8 bits"); XCTAssertEqual(d[i + 17], 6, "RGBA")
            }
            if type == "IDAT" { z += d[i + 8..<i + 8 + len] }
            i += 12 + len
        }
        var raw: [UInt8] = [], j = 2   // skip the zlib header
        while j < z.count - 4 {
            let header = z[j], last = header & 1
            guard (header >> 1) & 3 == 0 else { throw NSError(domain: "B100", code: 1, userInfo: [NSLocalizedDescriptionKey: "not stored; re-run Tools/b100_headermark.py"]) }
            let n = Int(z[j + 1]) | Int(z[j + 2]) << 8
            raw += z[j + 5..<j + 5 + n]
            j += 5 + n
            if last == 1 { break }
        }
        var px: [UInt8] = []
        for y in 0..<h {
            let row = raw[(y * (w * 4 + 1))..<((y + 1) * (w * 4 + 1))]
            XCTAssertEqual(row.first, 0, "filter 0")
            px += row.dropFirst()
        }
        return (w, h, px)
    }

    /// No light (white / light grey) pixel in the outer ring of the asset; the disc ends inside the 34 pt clip.
    func test_B100_noLightRimAroundTheHomeLogo() throws {
        for scale in ["2x", "3x"] {
            let url = appFolder.appendingPathComponent("Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@\(scale).png")
            let (w, h, px) = try storedPNG(url)
            XCTAssertEqual(w, h)
            let c = Double(w) / 2
            var light = 0, maxR = 0.0
            for y in 0..<h {
                for x in 0..<w {
                    let k = (y * w + x) * 4
                    let a = px[k + 3]
                    let r = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot() / c
                    if a > 0 { maxR = max(maxR, r) }
                    if r >= 0.85, a > 40, min(px[k], px[k + 1], px[k + 2]) > 150 { light += 1 }
                }
            }
            XCTAssertEqual(light, 0, "\(scale): light pixels in the outer ring")
            XCTAssertLessThan(maxR, 0.97, "\(scale): mask pulled in ~4 %")
            XCTAssertGreaterThan(maxR, 0.9, "\(scale): the disc is not shrunk more than needed")
        }
    }

    // MARK: N11-5 · B101 G500

    func test_B101_g500FoundAndNamed_unknownIgnored() {
        XCTAssertTrue(ScooterGatt.isScooter(name: "G500", manufacturerData: []))
        XCTAssertTrue(ScooterGatt.isScooter(name: "G2", manufacturerData: []))
        XCTAssertEqual(KnownScooters.modelName(advertisedName: "G500", makerTagged: false), "RND G500")
        XCTAssertFalse(ScooterGatt.isScooter(name: "Unknown", manufacturerData: []))
        XCTAssertEqual(KnownScooters.modelName(advertisedName: "Unknown", makerTagged: false), "Scooter")
    }

    // MARK: N11-1 · tyre-pressure hint (synthetic rides only; the extra-load estimate still needs the owner's real export)

    private let noise: [Double] = [0, 0.02, -0.02, 0.01, -0.01, 0.03, -0.03]

    private func ride(_ i: Int, _ whKm: Double, route: String? = "R", temp: Double = 20, gap: Double = 0, km: Double = 6,
                      wheel: Double? = 1.0, fw: String? = "6.1.2", pull: Double? = 100, rise: Double? = 15) -> EnergyRide {
        EnergyRide(rideId: "r\(i)", day: 100 + i, routeId: route, distanceKm: km, energyWh: whKm * km * (1 + noise[i % noise.count]),
                   airTempC: temp, headwindKmh: 5, wet: false, avgKmh: 18, stopsPerKm: 1, mainGear: 3, gapS: gap,
                   wheelOverGps: wheel, pull: pull, motorRiseC: rise, firmware: fw)
    }

    private func normalBook(_ n: Int = 15) -> (EnergyBook, Int) {
        var book = EnergyBook()
        for i in 0..<n { _ = EnergyHint.ride(&book, scooterId: "s", ride(i, 20), packWh: 500) }
        return (book, n)
    }

    func test_N11_1_normalNoiseNeverHints() {
        var book = EnergyBook()
        for i in 0..<60 {
            let o = EnergyHint.ride(&book, scooterId: "s", ride(i, 20), packWh: 500)
            XCTAssertEqual(o.stepAfter, .quiet, "ride \(i)")
        }
    }

    func test_N11_1_noHintWhileLearning() {
        var book = EnergyBook()
        for i in 0..<9 { _ = EnergyHint.ride(&book, scooterId: "s", ride(i, i < 4 ? 20 : 30), packWh: 500) }
        XCTAssertEqual(book.scooters["s"]?.step, .quiet)
        XCTAssertLessThan(book.scooters["s"]?.cleanRides ?? 99, EnergyRules.learningRides)
    }

    func test_N11_1_slowCreepGivesTheTyreHint_notBefore5Rides() {
        var (book, n) = normalBook()
        var firstHint: Int?
        for k in 1...15 {
            let o = EnergyHint.ride(&book, scooterId: "s", ride(n + k, 20 * (1 + 0.02 * Double(k))), packWh: 500)
            if firstHint == nil, o.stepAfter != .quiet { firstHint = k; XCTAssertEqual(o.stepAfter, .tyre) }
        }
        XCTAssertNotNil(firstHint)
        XCTAssertGreaterThanOrEqual(firstHint ?? 0, EnergyRules.creepRides)
        XCTAssertEqual(EnergyCopy.text(.tyre, tyre: .air)?.found, "Using more battery than usual on the same routes: check tyre pressure.")
        XCTAssertEqual(EnergyCopy.text(.tyre, tyre: .air)?.part, .tyres)
    }

    func test_N11_1_suddenJumpGivesTheBrakeWheelHint_after2Rides() {
        var (book, n) = normalBook()
        let o1 = EnergyHint.ride(&book, scooterId: "s", ride(n + 1, 27), packWh: 500)
        XCTAssertEqual(o1.stepAfter, .quiet, "one ride is never enough")
        let o2 = EnergyHint.ride(&book, scooterId: "s", ride(n + 2, 27), packWh: 500)
        XCTAssertEqual(o2.stepAfter, .brakeWheel)
        XCTAssertEqual(EnergyCopy.text(.brakeWheel, tyre: .air)?.part, .brakes)
    }

    func test_N11_1_ruledOut_coldGapsWheelDetourNoRoute() {
        var (book, n) = normalBook()
        for k in 1...3 {
            // cold rides use more: there are no similar cold rides yet, so nothing is compared (cold is ruled out)
            let o = EnergyHint.ride(&book, scooterId: "s", ride(n + k, 30, temp: 2), packWh: 500)
            XCTAssertNil(o.ratio)
        }
        XCTAssertEqual(EnergyHint.ride(&book, scooterId: "s", ride(n + 20, 30, gap: 60), packWh: 500).skipped, .gaps)
        XCTAssertEqual(EnergyHint.ride(&book, scooterId: "s", ride(n + 21, 30, wheel: 1.2), packWh: 500).skipped, .wheelOverGps)
        XCTAssertEqual(EnergyHint.ride(&book, scooterId: "s", ride(n + 22, 30, km: 9), packWh: 500).skipped, .detour)
        XCTAssertEqual(EnergyHint.ride(&book, scooterId: "s", ride(n + 23, 30, route: nil), packWh: 500).skipped, .noRoute)
        XCTAssertEqual(EnergyHint.ride(&book, scooterId: "s", ride(n + 24, 30, pull: 130), packWh: 500).ratio, nil, "extra load is ruled out")
        XCTAssertEqual(book.scooters["s"]?.step, .quiet)
    }

    func test_N11_1_noTapStillHighMovesOn_andPumpedBackToNormal() {
        var (book, n) = normalBook()
        _ = EnergyHint.ride(&book, scooterId: "s", ride(n + 1, 27), packWh: 500)
        _ = EnergyHint.ride(&book, scooterId: "s", ride(n + 2, 27), packWh: 500)
        XCTAssertEqual(book.scooters["s"]?.step, .brakeWheel)
        for k in 3...5 { _ = EnergyHint.ride(&book, scooterId: "s", ride(n + k, 27), packWh: 500) }
        XCTAssertEqual(book.scooters["s"]?.step, .shop, "no tap and still high after 3 rides -> the next step")

        var (b2, m) = normalBook()
        var k = 0
        while b2.scooters["s"]?.step == .quiet, k < 15 {
            k += 1
            _ = EnergyHint.ride(&b2, scooterId: "s", ride(m + k, 20 * (1 + 0.025 * Double(k))), packWh: 500)
        }
        XCTAssertEqual(b2.scooters["s"]?.step, .tyre)
        EnergyHint.tap(&b2, scooterId: "s", .pumped)
        _ = EnergyHint.ride(&b2, scooterId: "s", ride(m + k + 1, 19.5), packWh: 500)
        _ = EnergyHint.ride(&b2, scooterId: "s", ride(m + k + 2, 19.5), packWh: 500)
        XCTAssertEqual(b2.scooters["s"]?.step, .quiet)
        let line = EnergyHint.takeBackToNormal(&b2, scooterId: "s")
        XCTAssertTrue(line?.hasPrefix("Back to normal since you pumped: +") ?? false, line ?? "nil")
        XCTAssertTrue(line?.hasSuffix(" km of range") ?? false)
        XCTAssertNil(EnergyHint.takeBackToNormal(&b2, scooterId: "s"), "once")
    }

    func test_N11_1_fineTooIsTheNewNormal_nextRiseGoesToTheShop() {
        var (book, n) = normalBook()
        _ = EnergyHint.ride(&book, scooterId: "s", ride(n + 1, 27), packWh: 500)
        _ = EnergyHint.ride(&book, scooterId: "s", ride(n + 2, 27), packWh: 500)
        EnergyHint.tap(&book, scooterId: "s", .fineToo)
        XCTAssertEqual(book.scooters["s"]?.step, .quiet)
        for k in 3...12 { _ = EnergyHint.ride(&book, scooterId: "s", ride(n + k, 27), packWh: 500) }
        XCTAssertEqual(book.scooters["s"]?.step, .quiet, "27 Wh/km is the new normal")
        XCTAssertGreaterThan(EnergyHint.threshold(book.scooters["s"]!), EnergyRules.minThreshold, "a fine raises the bar")
    }

    func test_N11_1_firmwareChangeStartsANewNormal() {
        var (book, n) = normalBook()
        let o = EnergyHint.ride(&book, scooterId: "s", ride(n + 1, 20, fw: "7.0.0"), packWh: 500)
        XCTAssertEqual(o.skipped, .firmware)
        XCTAssertEqual(book.scooters["s"]?.cleanRides, 0)
    }

    func test_N11_1_tyreTypeFromModel_andRangeGain() {
        XCTAssertEqual(KnownScooters.tyre(model: "RND G500"), .air)
        XCTAssertEqual(KnownScooters.tyre(model: "Someone's scooter"), .unknown)
        XCTAssertEqual(EnergyCopy.text(.tyre, tyre: .unknown)?.what, "Check tyre pressure, or wear if the tyres are solid.")
        XCTAssertEqual(EnergyHint.kmGained(packWh: 500, normalWhPerKm: 20, highRatio: 1.1), 25 - 500 / 22, accuracy: 0.001)
        XCTAssertEqual(EnergyCopy.backToNormal(km: 1.4, afterPump: false), "Back to normal: +1.5 km of range")
    }

    /// Synthetic speed-ups: power = (m·a + rolling + air)·v ÷ 0.8. A 25 % heavier load shows as ~25 % more pull.
    func test_N11_1_loadEstimate_onSyntheticRides() {
        func points(mass: Double) -> [LoadEstimate.Point] {
            var pts: [LoadEstimate.Point] = []
            var v = 1.5
            for i in 0..<60 {
                let a = [0.4, 0.8, 1.2, 0.6, 1.0][i % 5]
                pts.append(LoadEstimate.Point(t: Double(i), speedMps: v, powerW: (mass * a + 15 + 0.3 * v * v) * v / 0.8 * (1 + noise[i % 7] / 4)))
                v += a
                if v > 7.5 { v = 1.5 }
            }
            return pts
        }
        let base = LoadEstimate.pull(points(mass: 100))
        let heavy = LoadEstimate.pull(points(mass: 125))
        XCTAssertNotNil(base); XCTAssertNotNil(heavy)
        if let base, let heavy { XCTAssertEqual(heavy / base, 1.25, accuracy: 0.06) }
        XCTAssertNil(LoadEstimate.pull(Array(points(mass: 100).prefix(5))), "too few speed-ups")
    }

    // MARK: N11-2 · Garage

    func test_N11_2_unknownScooterIsAdded_activeIsConnected_elseLastConnected() {
        var r = GarageRegistry()
        var isNew: Bool
        (r, isNew) = r.connected(id: "A", model: "RND G100", atMs: 1)
        XCTAssertTrue(isNew)
        (r, isNew) = r.connected(id: "B", model: "RND G500", atMs: 2)
        XCTAssertTrue(isNew)
        (r, isNew) = r.connected(id: "A", model: "RND G100", atMs: 3)
        XCTAssertFalse(isNew)
        XCTAssertEqual(r.scooters.count, 2)
        XCTAssertEqual(r.active(connectedId: "B")?.id, "B")
        XCTAssertEqual(r.active(connectedId: nil)?.id, "A", "not connected -> the last one connected")
        XCTAssertEqual(r.scooter("B")?.displayName, "RND G500", "named after its model")
        XCTAssertTrue(r.showsGarage)
    }

    func test_N11_2_soldLostRemove_keepEverything_andLockScreenName() {
        var r = GarageRegistry()
        r = r.connected(id: "A", model: "RND G100", atMs: 1).0
        XCTAssertEqual(r.lockScreenName(activeId: "A"), "Scooter", "one scooter: the plain word")
        r = r.connected(id: "B", model: "RND G500", atMs: 2).0
        r = r.renamed("B", to: "  Big one ")
        XCTAssertEqual(r.lockScreenName(activeId: "B"), "Big one", "2+ scooters: the name")
        r = r.retire("A", as: .lost, atMs: 5)
        XCTAssertEqual(r.scooter("A")?.status.label, "Lost")
        XCTAssertEqual(r.scooters.count, 2, "nothing is deleted")
        XCTAssertEqual(r.inUse.map(\.id), ["B"])
        XCTAssertEqual(r.active(connectedId: "A")?.id, "B", "a lost scooter is never the active one")
        XCTAssertEqual(r.retire("B", as: .active, atMs: 6), r, "active is not a way to leave")
        // found again: it connects, so it is back
        r = r.connected(id: "A", model: "RND G100", atMs: 7).0
        XCTAssertEqual(r.scooter("A")?.status, .active)
        let decoded = GarageRegistry.decode(r.encoded())
        XCTAssertEqual(decoded, r)
        XCTAssertEqual(GarageRegistry.decode(nil), GarageRegistry())
    }

    func test_N11_2_legacyRidesGoToTheScooterInUseAtTheTime() {
        let map = GarageLegacy.assign(rideStartsMs: ["old": 5, "g2": 150, "g500": 900],
                                      scooters: [(id: "G2", firstSeenMs: 100), (id: "G500", firstSeenMs: 800)])
        XCTAssertEqual(map, ["old": "G2", "g2": "G2", "g500": "G500"])
        XCTAssertEqual(GarageLegacy.assign(rideStartsMs: ["x": 1], scooters: []), [:])
    }

    func test_N11_2_swapParksTheOldScooterAndLoadsTheNew() {
        let plan = GarageSwap.plan(from: "A", to: "B")
        XCTAssertEqual(plan.moves.first?.from, "battery.packAh")
        XCTAssertEqual(plan.moves.first?.to, "battery.packAh@A")
        XCTAssertTrue(plan.moves.contains { $0.from == "battery.packAh@B" && $0.to == "battery.packAh" })
        XCTAssertTrue(plan.moves.contains { $0.from == "scooter.customName@B" && $0.to == "scooter.customName" })
        XCTAssertTrue(GarageSwap.plan(from: "A", to: "A").moves.isEmpty)
        XCTAssertTrue(DataMap.isScooterSetting("battery.packAh@A"), "a parked key is scooter data (Start fresh, leak check)")
        XCTAssertTrue(DataMap.isScooterSetting("garage.registry"))
    }

    func test_N11_2_statsAllScootersByDefault_filterFrom2() {
        var r = GarageRegistry()
        r = r.connected(id: "A", model: "RND G100", atMs: 1).0
        XCTAssertEqual(GarageStatsFilter.options(r), [.all])
        r = r.connected(id: "B", model: "RND G500", atMs: 2).0
        XCTAssertEqual(GarageStatsFilter.options(r), [.all, .scooter("A"), .scooter("B")])
        XCTAssertTrue(GarageStatsFilter.all.includes(rideScooterId: "A"))
        XCTAssertFalse(GarageStatsFilter.scooter("B").includes(rideScooterId: "A"))
        XCTAssertEqual(GarageStatsFilter.all.label(r), "All scooters")
        XCTAssertTrue(GarageLearning.isLearning(ridesOnScooter: 9, borrowing: false))
        XCTAssertFalse(GarageLearning.isLearning(ridesOnScooter: 10, borrowing: false))
        XCTAssertTrue(GarageLearning.isLearning(ridesOnScooter: 50, borrowing: true))
    }

    /// The app wiring stays: rides tagged at the start, Lost never mentions anything near, Sold / Lost keep the service book
    func test_N11_2_appWiring() throws {
        XCTAssertTrue(try text("Recorder/Recorder.swift").contains("GarageService.tagId(db)"))
        let garage = try text("UI/Scooter/GarageView.swift")
        XCTAssertTrue(garage.contains("MaintenanceHistoryView(scooterId: s.id)"))
        XCTAssertFalse(garage.lowercased().contains("nearby"), "Lost: no nearby notification (owner 23 Nov)")
        XCTAssertFalse(garage.lowercased().contains("stolen"), "the owner's word is Lost")
        let link = try text("Adapters/ScooterLink.swift")
        XCTAssertFalse(link.contains("writeValue"), "read-only")
    }

    // MARK: N11-4 · thank-you hero line + one-time confetti

    func test_N11_4_heroLineAndConfettiOnceNoReduceMotion() throws {
        let entries = try WhatsNew.decode(try Data(contentsOf: appFolder.appendingPathComponent("Resources/WhatsNew.json")))
        // B102: hotfix 111.291126.01 sits above it; the thank-you belongs to 111.291126.00 only
        guard let top = entries.first(where: { $0.version == "111.291126.00" }) else { return XCTFail("no 111.291126.00 entry") }
        XCTAssertEqual(top.hero, "Bug #100 fixed \u{1F389} Thanks for every report.")
        XCTAssertEqual(top.confetti, true)
        XCTAssertTrue(entries.filter { $0.version != top.version }.allSatisfy { $0.confetti != true }, "only this version")
        XCTAssertTrue(WhatsNew.showConfetti(top, reduceMotion: false, alreadyShown: false))
        XCTAssertFalse(WhatsNew.showConfetti(top, reduceMotion: true, alreadyShown: false), "Reduce Motion: the line only")
        XCTAssertFalse(WhatsNew.showConfetti(top, reduceMotion: false, alreadyShown: true), "once")
        XCTAssertEqual(WhatsNew.confettiSeconds, 2)
        let views = try text("UI/Shared/WhatsNewViews.swift")
        XCTAssertFalse(views.contains("SoundPlayer"), "no sound")
        XCTAssertTrue(views.contains("simultaneousGesture(TapGesture()"), "tap anywhere ends it")
    }
}
