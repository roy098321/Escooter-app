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

/// u43 (M6-02, Q23 live): the nine made-up rides ridden again through the live screen with Follow on a temporary database:
/// the prompt ~15 s ahead and gone after the split, one at a time, gates (< 20 s, < 30 m), the usual way taken = quiet re-plan.
enum PromptCheck {
    typealias Run = (prompts: [(along: Double, text: String)], other: Int, driver: LiveScreenDriver)

    static func ride(_ follower: RouteFollower, _ spec: ChoiceSamples.Spec, _ p: ChoicePrompter?) -> Run {
        var d = LiveScreenDriver()
        d.follow(follower, prompts: p)
        var out: [(along: Double, text: String)] = []
        var other = 0
        var along = 0.0
        var last: GeoPoint?
        for fix in ChoiceSamples.ride(id: "u43", startAt: ChoiceSamples.t0, spec: spec, seed: 7).choice.fixes {
            let g = GeoPoint(lat: fix.lat, lon: fix.lon)
            if let l = last { along += Geo.distanceM(l, g) }
            last = g
            let input = LiveInput(scooterSpeedKmh: 22, scooterBatteryPct: 80, lat: fix.lat, lon: fix.lon, rideElapsedS: fix.t, rideDistanceM: along)
            let s = d.update(input, at: fix.t)
            if s.banner?.banner == .choicePoint, let t = s.bannerText {
                out.append((along: along, text: t))
            } else if s.banner != nil {
                other += 1
            }
        }
        return (prompts: out, other: other, driver: d)
    }

    static func run() {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        do {
            let db = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { db.discardTemporary() }
            try ChoiceSeed.route(db)
            let now = ChoiceSamples.t0 + 20 * ChoiceSamples.day
            guard let combo = FastestService.answer(db, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: [])?.combo,
                  let follower = RouteFollowLoader.follower(routeId: ChoiceSamples.routeId, database: db, nowMs: now, combination: true),
                  let prompter = FastestService.prompter(db, routeId: ChoiceSamples.routeId, nowMs: now) else {
                results.set("u43", .fail, "No combination or prompter from the made-up rides")
                return
            }
            let planned = ride(follower, ChoiceSamples.Spec(.park, left: true), prompter)
            let first = planned.prompts.first
            let aheadOk = first.map { 800 - $0.along >= 70 && 800 - $0.along <= 100 } ?? false
            let goneOk = planned.prompts.filter { $0.along > 900 && $0.along < 2_200 }.isEmpty
            let secondOk = planned.prompts.contains { $0.along > 2_000 }
            let countOk = planned.driver.promptsShownNow == 2
            let notFollowingOk = ride(follower, ChoiceSamples.Spec(.park, left: true), nil).prompts.isEmpty
            // gates
            var small = combo
            small.ways = small.ways.map { var w = $0; w.savingS = 15; return w }
            var close = combo
            close.ways = close.ways.map { var w = $0; w.apartM = 20; return w }
            let set = try ChoiceQueries(db).set(routeId: ChoiceSamples.routeId, reference: ChoiceSamples.reference)
            let gatesOk = ride(follower, ChoiceSamples.Spec(.park, left: true), ChoicePrompter(combo: small, points: set.points)).prompts.isEmpty
                && ride(follower, ChoiceSamples.Spec(.park, left: true), ChoicePrompter(combo: close, points: set.points)).prompts.isEmpty
            // the usual way taken where the park was chosen: no prompt after, no other message, path re-planned
            let other = ride(follower, ChoiceSamples.Spec(.usual, left: true), FastestService.prompter(db, routeId: ChoiceSamples.routeId, nowMs: now))
            let quietOk = other.prompts.filter { $0.along > 900 && $0.along < 2_200 }.isEmpty && other.other == 0
                && other.driver.followedPath?.count != follower.path.count && other.driver.choiceReplansNow == 1
            let all = aheadOk && goneOk && secondOk && countOk && notFollowingOk && gatesOk && quietOk
            results.set("u43", all ? .pass : .fail,
                        "15 s ahead \(word(aheadOk)) · gone after the split \(word(goneOk)) · second prompt \(word(secondOk)) · counted \(word(countOk)) · not following: none \(word(notFollowingOk)) · gates (< 20 s, < 30 m) \(word(gatesOk)) · quiet re-plan \(word(quietOk)) · first: \(first?.text ?? "-")")
        } catch {
            results.set("u43", .fail, "The temporary database failed: \(error.localizedDescription)")
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
