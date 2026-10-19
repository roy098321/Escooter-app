import CorckieCore
import Foundation
import GRDB
import SwiftUI

/// u42 (M6-01, Q23): the made-up choice-point rides (`ChoiceSeed`) in temporary databases: the tables are filled, the fastest
/// combination is the never-ridden park + left mix, the Follow path stays on ridden stretches, an option seen twice waits ("2 of 3"),
/// Q3 gets a verdict; ends with this phone's choice points.
enum FastestCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        do {
            let a = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { a.discardTemporary() }
            let ids = try ChoiceSeed.route(a)
            let now = ChoiceSamples.t0 + 20 * ChoiceSamples.day
            let counts = try ChoiceQueries(a).counts(routeId: ChoiceSamples.routeId)
            let tablesOk = counts.points == 2 && counts.options == 4 && counts.rideOptions == 18

            let answer = FastestService.answer(a, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: [])
            var comboOk = false
            var pathOk = false
            var timeText = "-"
            if let answer, case .combination(let c) = answer.state {
                comboOk = c.ways.count == 2 && c.ways.allSatisfy { !$0.isReference } && c.savingS >= 66
                timeText = FastestCard.clock(c.timeS)
                let ridden = try ChoiceQueries(a).rides(routeId: ChoiceSamples.routeId, limit: 40).map { r in r.fixes.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
                pathOk = c.path.count > 10 && c.path.allSatisfy { p in (ridden.map { Geo.distanceToPathM(p, $0) }.min() ?? .infinity) < 30 }
            }
            // Follow: the combination's path and time reach the live follower
            let follow = RouteFollowLoader.follower(routeId: ChoiceSamples.routeId, database: a, nowMs: now, combination: true)
            let followOk = follow.map { abs($0.todayS - (answer?.combo?.timeS ?? -1)) < 1 } ?? false

            // gate: "left" only twice → waits, the usual way is kept there
            let b = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { b.discardTemporary() }
            let few = Array(repeating: ChoiceSamples.Spec(.usual, left: false), count: 3) + Array(repeating: ChoiceSamples.Spec(.park, left: false), count: 3)
                + Array(repeating: ChoiceSamples.Spec(.usual, left: true), count: 2)
            try ChoiceSeed.route(b, specs: few)
            let fewAnswer = FastestService.answer(b, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: [])
            let card = fewAnswer.flatMap(FastestCard.make)
            let gateOk = fewAnswer?.waiting.first?.have == 2 && card?.canFollow == false

            // Q3: the park rides get their stretch compared (verdict at the 3rd park ride)
            try InsightRunner.afterRide(a, rideId: ids[5], nowMs: now)
            let q3 = try a.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM insight WHERE type IN ('q3After', 'q3Verdict') AND rideId = ?", arguments: [ids[5]])
            }
            let q3Ok = q3.contains { $0.contains("Verdict") }

            var phone = "no data"
            if let real, let n = try? real.writer.read({ db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM choice_point") ?? 0 }) {
                phone = "\(n) choice points on this phone"
            }
            let all = tablesOk && comboOk && pathOk && followOk && gateOk && q3Ok
            results.set("u42", all ? .pass : .fail,
                        "tables \(word(tablesOk)) (\(counts.points) points, \(counts.options) options, \(counts.rideOptions) times) · fastest = park + left ~\(timeText) \(word(comboOk)) · path on ridden stretches \(word(pathOk)) · Follow \(word(followOk)) · 2 of 3 waits \(word(gateOk)) · Q3 verdict \(word(q3Ok)) · \(phone)")
        } catch {
            results.set("u42", .fail, "The temporary database failed: \(error.localizedDescription)")
        }
    }
}

/// u44 (M6-05, C15): every screen in every state of the ui-shot list is built and drawn off-screen, once at the normal text size and once
/// at the largest accessibility size; none may crash or come out blank.
@MainActor
enum StatesCheck {
    static func looksBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = 24
        let h = 48
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return true }
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: px.count, by: 4) {
            seen.insert(UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2]))
        }
        return seen.count < 2
    }

    static func render(_ name: String, big: Bool, window: UIWindow, root: UIViewController) async -> UIImage {
        let view = UIShot.screen(name).dynamicTypeSize(big ? DynamicTypeSize.accessibility5 : DynamicTypeSize.large)
        let host = UIHostingController(rootView: view)
        let frame = CGRect(x: 3_000, y: 0, width: 390, height: 844)
        root.addChild(host)
        host.view.frame = frame
        window.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 120_000_000)
        let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: frame.size), afterScreenUpdates: true)
        }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        return image
    }

    static func run() async {
        let results = CheckResults.shared
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first, let root = window.rootViewController else {
            results.set("u44", .fail, "No window to draw in")
            return
        }
        var blank: [String] = []
        for name in UIShot.allNames {
            if looksBlank(await render(name, big: false, window: window, root: root)) { blank.append(name) }
            if looksBlank(await render(name, big: true, window: window, root: root)) { blank.append(name + " (large text)") }
        }
        let n = UIShot.allNames.count
        results.set("u44", blank.isEmpty ? .pass : .fail,
                    blank.isEmpty ? "\(n) screens and states drawn at normal and largest text, none blank"
                                  : "\(n) screens drawn, blank: " + blank.joined(separator: ", "))
    }
}

/// u45 (M6-06, C28): the edge-case rules from Core on made-up values, and the early thinning of raw data on a temporary database.
enum EdgeCheck {
    static func run() {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let battery: Bool = PhoneBatteryPolicy.gps(pct: 25, charging: false, lowPowerMode: false) == .normal
            && PhoneBatteryPolicy.gps(pct: 19, charging: false, lowPowerMode: false) == .reduced
            && PhoneBatteryPolicy.gps(pct: 9, charging: false, lowPowerMode: false) == .off
            && PhoneBatteryPolicy.gps(pct: 9, charging: true, lowPowerMode: false) == .normal
            && PhoneBatteryPolicy.gps(pct: 60, charging: false, lowPowerMode: true) == .reduced
        let banner: Bool = {
            var d = LiveScreenDriver()
            let input = LiveInput(scooterSpeedKmh: 20, scooterBatteryPct: 70, secondsWithoutGps: 30, rideElapsedS: 60, phoneGpsOff: true)
            _ = d.update(input, at: 1)
            let s = d.update(input, at: 2)
            return s.banner?.banner == .phoneBatteryLow && s.tiles.speedKmh == 20
        }()
        let storage: Bool = StoragePolicy.level(freeBytes: 2_000_000_000) == .ok
            && StoragePolicy.level(freeBytes: 800_000_000) == .thin
            && StoragePolicy.level(freeBytes: 100_000_000) == .warn
        let now: Int64 = 1_800_000_000_000
        let day: Int64 = 86_400_000
        let expiry: Bool = AppExpiry.plan(expiryMs: now + 3 * day, nowMs: now) == .remind(atMs: now + 2 * day)
            && AppExpiry.plan(expiryMs: now + day / 4, nowMs: now) == .soon(hoursLeft: 6)
            && AppExpiry.plan(expiryMs: now - 1, nowMs: now) == .expired
        let clock: Bool = {
            let g = ClockGuard(wall: 1_000, mono: 10)
            return g.isJump(wall: 1_000 + 3_600 + 60, mono: 70) && !g.isJump(wall: 1_060.5, mono: 70)
                && abs(g.engineTime(ofWall: 1_000 + 3_600 + 58, wall: 1_000 + 3_600 + 60, mono: 70) - 1_058) < 0.001
        }()
        var thin = "-"
        var thinOk = false
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            try RideToolsSeed.ride(temp, id: "R1", startAt: now - 100 * day)
            let q = RideQueries(temp)
            try q.insert(chunk: RawChunkRecord(rideId: "R1", seq: 0, startAt: now - 100 * day, endAt: now - 99 * day, kind: "scooter", blob: Data([1])))
            try q.insert(chunk: RawChunkRecord(rideId: "R1", seq: 1, startAt: now - 100 * day, endAt: now - 99 * day, kind: "energy", blob: Data([1])))
            try q.insert(chunk: RawChunkRecord(rideId: "R1", seq: 2, startAt: now - 3 * day, endAt: now - 2 * day, kind: "scooter", blob: Data([1])))
            let cutoff = StoragePolicy.thinCutoffMs(.thin, nowMs: now) ?? 0
            let deleted = try RetentionService.thinEarly(temp, cutoffMs: cutoff)
            let left = try temp.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM raw_chunk") ?? 0 }
            let rides = try temp.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") ?? 0 }
            thinOk = deleted == 1 && left == 2 && rides == 1
            thin = "\(deleted) old raw chunk removed, \(left) kept (energy + recent), \(rides) ride"
        } catch {
            thin = error.localizedDescription
        }
        let realNow = Int64(Date().timeIntervalSince1970 * 1000)
        let expiryText = EdgeWatch.expiryMs().map { "\(($0 - realNow) / day) days left" } ?? "unknown (no profile)"
        let phone = (EdgeWatch.freeStorageBytes().map { "\($0 / 1_000_000) MB free" } ?? "free space unknown") + ", app signature: " + expiryText
        let all = battery && banner && storage && expiry && clock && thinOk
        results.set("u45", all ? .pass : .fail,
                    "phone battery 20% / 10% / charging / Low Power Mode \(word(battery)) · banner Phone battery low, tiles untouched \(word(banner)) · storage levels \(word(storage)) · expiry reminder 1 day before \(word(expiry)) · clock change keeps the ride's timeline \(word(clock)) · early thinning keeps energy, recent data and rides \(word(thinOk)) (\(thin)) · this phone: \(phone)")
    }
}
