import CorckieCore
import Foundation

/// u38 (M5-01 / M5-02): compare rows and suggestions, the merge offer rule, and in a temporary database a real merge (numbers add up,
/// the pause is a stop and not missing data, the second ride is gone), Undo (both rides back, same numbers), trim (numbers from the
/// window) and Reset trim (the original numbers back).
enum RideToolsCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let a = CompareRide(id: "a", routeId: "r", variantId: "v", distanceM: 5_000, totalS: 1_200, usedPct: 10)
        let b = CompareRide(id: "b", startAt: 5, routeId: "r", variantId: "w", distanceM: 5_000, totalS: 1_270, usedPct: 12)
        let rows = RideCompareBuilder.rows(a, b)
        let c1: Bool = rows.count == 9
        let c2: Bool = rows[0].difference == "\u{2212}1 min 10 s"
        let c3: Bool = RideCompareBuilder.relation(a, b) == "Same route"
        let c4: Bool = RideCompareBuilder.suggestions(for: a, among: [a, b]).map(\.id) == ["b"]
        let compareOk = c1 && c2 && c3 && c4
        let prev = MergeEnd(id: "p", startAt: 0, endAt: 1_000_000, endLat: 10, endLon: 20)
        let near = MergeEnd(id: "n", startAt: 1_600_000, endAt: nil, startLat: 10.000_5, startLon: 20)
        let late = MergeEnd(id: "l", startAt: 3_000_000, endAt: nil, startLat: 10, startLon: 20)
        let offerOk: Bool = RideMerge.offer(previous: prev, next: near) != nil && RideMerge.offer(previous: prev, next: late) == nil
        let clampOk: Bool = RideTrim.clamp(startS: 440, endS: 450, lastS: 500).map { $0.end - $0.start == 60 } == true

        var dbOk = false
        var detail = "?"
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-undo-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let t0: Int64 = 1_790_000_000_000
            try RideToolsSeed.ride(temp, id: "A", startAt: t0)
            try RideToolsSeed.ride(temp, id: "B", startAt: t0 + 1_095_000, odoStartKm: 102.475, lat0: 10.0198)
            let q = RideQueries(temp)
            let before = try q.ride(id: "A")?.distanceM ?? 0
            let offered = RideToolsService.mergeOffer(temp, rideId: "B") != nil
            try RideToolsService.merge(temp, firstId: "A", secondId: "B", nowMs: t0 + 2_000_000, undoFolder: folder)
            let merged = try q.ride(id: "A")
            let gone = try q.ride(id: "B") == nil
            let samples = try q.sampleCount(rideId: "A")
            let mergedKm: Double = merged?.distanceM ?? 0
            let m1: Bool = abs(mergedKm - 4_950) < 2
            let m2: Bool = merged?.stops == 1
            let m3: Bool = (merged?.gapScooterS ?? 99) < 1
            let mergeOk: Bool = offered && gone && samples == 200 && m1 && m2 && m3
            try RideToolsService.undoMerge(temp, undoFolder: folder)
            let backA = try q.ride(id: "A")
            let backB = try q.ride(id: "B")
            let countA = try q.sampleCount(rideId: "A")
            let countB = try q.sampleCount(rideId: "B")
            let backKm: Double = backA?.distanceM ?? 0
            let u1: Bool = backA != nil && backB != nil
            let u2: Bool = abs(backKm - before) < 0.5
            let u3: Bool = countA == 100 && countB == 100
            let undoOk: Bool = u1 && u2 && u3 && !RideToolsService.canUndoMerge(temp)
            try RideToolsService.trim(temp, rideId: "A", startS: 100, endS: 300)
            let cut = try q.ride(id: "A")
            let countCut = try q.sampleCount(rideId: "A")
            let cutKm: Double = cut?.distanceM ?? 0
            let trimOk: Bool = abs(cutKm - 1_000) < 2 && cut?.trimStartAt != nil && countCut == 100
            try RideToolsService.resetTrim(temp, rideId: "A")
            let reset = try q.ride(id: "A")
            let resetKm: Double = reset?.distanceM ?? 0
            let resetOk: Bool = reset?.trimStartAt == nil && abs(resetKm - before) < 0.5
            dbOk = mergeOk && undoOk && trimOk && resetOk
            detail = "merge \(word(mergeOk)), undo \(word(undoOk)), trim \(word(trimOk)), reset trim \(word(resetOk))"
        } catch {
            results.set("u38", .fail, "The temporary database failed: \(error.localizedDescription)")
            return
        }
        var phone = "no data"
        if let real, let rides = try? RideQueries(real).rides() {
            phone = "\(rides.count) rides, \(rides.filter { $0.trimStartAt != nil }.count) trimmed"
        }
        results.set("u38", compareOk && offerOk && clampOk && dbOk ? .pass : .fail,
                    "compare rows + same route first \(word(compareOk)) · merge offer 30 min / 200 m \(word(offerOk)) · trim minimum 1 min \(word(clampOk)) · \(detail) · this phone: \(phone)")
    }
}

/// u39 (M5-04): the replay page. Data rules in Core (1 Hz timeline, tile cap, no outside address in the download, the B01 chart fix,
/// speeds 1/4x to 50x), then a real web view loads the page and runs its own 5-second test at 50x (no errors, the position moves 250 s).
enum ReplayCheck {
    @MainActor
    static func run() async {
        let results = CheckResults.shared
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        guard let data = ReplayDataLoader.sample(seconds: 300) else {
            results.set("u39", .fail, "The sample replay data could not be made")
            return
        }
        let standalone = ReplayHTML.build(data) { _ in "data:image/png;base64,iVBORw0KGgo=" }
        let inApp = ReplayHTML.build(data) { ReplaySchemeHandler.href($0) }
        let tiles = ReplayBuilder.tiles(for: data)
        let tileOk: Bool = !tiles.isEmpty && tiles.count <= ReplayBuilder.maxTiles
        let offlineOk: Bool = !standalone.contains("http://") && !standalone.contains("https://")
        let ratesOk: Bool = standalone.contains("var RATES = [0.25, 0.5, 1, 2, 5, 10, 20, 50];")
        let fixOk: Bool = standalone.contains("fix 2026-10-03") && inApp.contains("corckie-tile://t/")
        let pointsOk: Bool = data.spd.count == 301 && data.x.count == 301

        let json = await ReplayProbe().run(html: standalone)
        var pageOk = false
        var pageText = json
        if let bytes = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            let ready = obj["ready"] as? Bool ?? false
            let errors = (obj["errors"] as? [Any])?.count ?? 99
            let test = obj["test"] as? [String: Any]
            let pos = test?["pos"] as? Double ?? -1
            let n = test?["n"] as? Double ?? 0
            let rate = test?["rate"] as? Double ?? 0
            pageOk = ready && errors == 0 && abs(pos - 250) < 1.5 && n == 301 && rate == 50
            pageText = "ready \(ready), \(errors) errors, 5 s at \(Int(rate))x moved to \(Int(pos)) of \(Int(n)) s"
        }
        results.set("u39", tileOk && offlineOk && ratesOk && fixOk && pointsOk && pageOk ? .pass : .fail,
                    "1 point per second \(word(pointsOk)) · \(tiles.count) tiles (max \(ReplayBuilder.maxTiles)) \(word(tileOk)) · no outside address in the file \(word(offlineOk)) · "
                    + "1/4x to 50x \(word(ratesOk)) · chart fix + in-app tile address \(word(fixOk)) · in a web view: \(pageText) \(word(pageOk)) · tile cache on this phone: \(TileCache.shared.sizeText())")
    }
}
