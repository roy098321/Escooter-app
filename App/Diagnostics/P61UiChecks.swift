import CorckieCore
import CorckieSim
import CoreGraphics
import Foundation

/// P6-1 chunk 2 checks on made-up data: u55 the short stiff bounce and the room under the floating bar (B20 / B23), u56 the live tile
/// sizes and the camera glide (B21 / B22 / F-10), u57 the way back of a saved route is saved at once (B24 follow-up).
enum P61UiChecks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " · ") }
    }

    static func run(real: AppDatabase?) {
        runBounce()
        runLive()
        runSavedWayBack()
    }

    // MARK: u55

    private static func runBounce() {
        let expect = Expect()
        let cap = StiffBounce.capPt
        expect(StiffBounce.damped(0) == 0 && StiffBounce.damped(10_000) <= cap + 0.01, "overscroll never passes the \(Int(cap)) pt cap")
        expect(StiffBounce.damped(20) < 10, "a pull of 20 pt gives under 10 pt (stiffer than stock)")
        expect(StiffBounce.clamped(y: -500, top: 0, bottom: 1_000) >= -cap - 0.01 && StiffBounce.clamped(y: 1_900, top: 0, bottom: 1_000) <= 1_000 + cap + 0.01,
               "both ends capped")
        expect(StiffBounce.clamped(y: 400, top: 0, bottom: 1_000) == 400, "inside the content nothing changes")
        expect(FloatingTabBar.clearance >= FloatingTabBar.barHeight + 24, "bottom margin covers the bar and the raised Home disc")
        CheckResults.shared.set("u55", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u56

    private static func runLive() {
        let expect = Expect()
        expect(LiveRideView.speedPt >= 76 && LiveRideView.tilePt >= 60, "speed \(Int(LiveRideView.speedPt)) pt (min 76), battery and ride time \(Int(LiveRideView.tilePt)) pt (min 60)")
        let metre = 1.0 / 111_320.0
        var track = LiveCameraTrack()
        _ = track.fix(lat: 10, lon: 20, atS: 0, speedKmh: 36)
        let u = track.fix(lat: 10 + 10 * metre, lon: 20, atS: 1, speedKmh: 36)
        expect(abs((u.headingDeg ?? 99) - 0) < 1 && u.durationS == 1, "heading follows the course (north), glide lasts the fix interval")
        let ahead = (u.centerLat - 10 - 10 * metre) / metre
        expect(ahead > 9 && ahead <= 15.01, "camera aims \(Int(ahead.rounded())) m ahead of the fix (at most 1.5 s)")
        let held = track.fix(lat: 10 + 12 * metre, lon: 20 + 3 * metre, atS: 2, speedKmh: 1)
        expect(held.headingDeg == u.headingDeg, "heading held when slower than 5 km/h")
        CheckResults.shared.set("u56", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u57

    private static func runSavedWayBack() {
        let expect = Expect()
        let base: Int64 = 1_790_000_000_000
        func at(_ k: Double) -> Int64 { base + Int64(k * 86_400_000) }
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = RouteQueries(temp)
            func ride(_ id: String, _ path: [SyntheticRoutes.XY], _ k: Double) throws -> RouteProcessResult? {
                try RouteFixtures.insertRide(temp, id: id, path: path, startAt: at(k))
                return try RouteProcessor.process(rideId: id, database: temp)
            }
            _ = try ride("a", SyntheticRoutes.main, 0)
            let b = try ride("b", SyntheticRoutes.main, 1)
            guard let forward = b?.routeId else { throw CocoaError(.fileReadUnknown) }
            try RouteService.save(routeId: forward, database: temp)
            let c = try ride("c", SyntheticRoutes.reversed(SyntheticRoutes.main), 1.4)
            let backState = try c?.routeId.flatMap { try store.route(id: $0) }?.state
            expect(c?.outcome == .matched && backState == "saved", "way back of a saved route is saved at once")
            if let id = c?.routeId {
                try RouteService.remove(routeId: id, database: temp)
                expect(try store.route(id: id)?.state == "dismissed", "Not a route / Remove still work")
            }
        } catch {
            expect(false, "temporary database: \(error.localizedDescription)")
        }
        CheckResults.shared.set("u57", expect.ok ? .pass : .fail, expect.line)
    }
}
