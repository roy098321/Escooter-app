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
        let compareOk: Bool = rows.count == 9 && rows[0].difference == "\u{2212}1 min 10 s" && RideCompareBuilder.relation(a, b) == "Same route"
            && RideCompareBuilder.suggestions(for: a, among: [a, b]).map(\.id) == ["b"]
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
            let mergeOk: Bool = offered && gone && samples == 200 && abs((merged?.distanceM ?? 0) - 4_950) < 2
                && merged?.stops == 1 && (merged?.gapScooterS ?? 99) < 1
            try RideToolsService.undoMerge(temp, undoFolder: folder)
            let backA = try q.ride(id: "A")
            let backB = try q.ride(id: "B")
            let countA = try q.sampleCount(rideId: "A")
            let countB = try q.sampleCount(rideId: "B")
            let undoOk: Bool = backA != nil && backB != nil && abs((backA?.distanceM ?? 0) - before) < 0.5
                && countA == 100 && countB == 100 && !RideToolsService.canUndoMerge(temp)
            try RideToolsService.trim(temp, rideId: "A", startS: 100, endS: 300)
            let cut = try q.ride(id: "A")
            let countCut = try q.sampleCount(rideId: "A")
            let trimOk: Bool = abs((cut?.distanceM ?? 0) - 1_000) < 2 && cut?.trimStartAt != nil && countCut == 100
            try RideToolsService.resetTrim(temp, rideId: "A")
            let reset = try q.ride(id: "A")
            let resetOk: Bool = reset?.trimStartAt == nil && abs((reset?.distanceM ?? 0) - before) < 0.5
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
