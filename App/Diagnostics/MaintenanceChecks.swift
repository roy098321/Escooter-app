import CorckieCore
import Foundation

/// u26 (M3-06): maintenance by km on made-up odometer values in a temporary database; the real rows are never touched.
enum MaintenanceCheck {
    static func run() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u26", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let q = MaintenanceQueries(temp)
            let t0: Int64 = 1_790_000_000_000
            try q.insertMissing(Maintenance.defaults(odoKm: 100, nowMs: t0).map(MaintenanceService.record))
            let items = try q.all().map(MaintenanceService.item)
            let defaultsOk = items.map(\.id) == ["tyres", "brakes", "bolts"] && items[0].hint.contains("50 PSI")
            // 100 km later nothing is due; 305 km later tyres and bolts are, brakes (500 km) are not
            let early = Maintenance.toRemind(items, odoKm: 200, nowMs: t0 + 3_600_000).map(\.id)
            let due = Maintenance.toRemind(items, odoKm: 405, nowMs: t0 + 3_600_000).map(\.id)
            let kmOk = early.isEmpty && due == ["tyres", "bolts"]
            // reminded once, again after 3 days, never after Mark done
            var tyres = items[0]
            tyres.notifiedAt = t0
            let once = Maintenance.toRemind([tyres], odoKm: 405, nowMs: t0 + 86_400_000).isEmpty
            let again = Maintenance.toRemind([tyres], odoKm: 405, nowMs: t0 + 3 * 86_400_000).count == 1
            let done = Maintenance.markedDone(tyres, odoKm: 405, nowMs: t0)
            try q.save(MaintenanceService.record(done))
            let doneOk = Maintenance.toRemind([done], odoKm: 410, nowMs: t0 + 4 * 86_400_000).isEmpty
            // quiet hours, daily limit, ride active
            let midnight: Int64 = 20_000 * 86_400_000
            let quiet = Maintenance.decide(nowMs: midnight + 23 * 3_600_000, utcOffsetMin: 0, rideActive: false, sentToday: 0) == .drop(reason: "quiet hours")
            let limit = Maintenance.decide(nowMs: midnight + 12 * 3_600_000, utcOffsetMin: 0, rideActive: false, sentToday: 2) == .drop(reason: "daily limit")
            let ride = Maintenance.decide(nowMs: midnight + 12 * 3_600_000, utcOffsetMin: 0, rideActive: true, sentToday: 0) == .drop(reason: "ride active")
            let sendOk = Maintenance.decide(nowMs: midnight + 12 * 3_600_000, utcOffsetMin: 0, rideActive: false, sentToday: 1) == .send
            let ok = defaultsOk && kmOk && once && again && doneOk && quiet && limit && ride && sendOk
            results.set("u26", ok ? .pass : .fail,
                        "defaults tyres 50 PSI / brakes / bolts \(defaultsOk ? "ok" : "wrong") · due by km \(kmOk ? "ok" : "wrong") · once, again after 3 days \(once && again ? "ok" : "wrong") · "
                        + "Mark done \(doneOk ? "ok" : "wrong") · quiet hours \(quiet ? "ok" : "wrong"), 2 a day \(limit ? "ok" : "wrong"), never in a ride \(ride ? "ok" : "wrong"), otherwise sends \(sendOk ? "ok" : "wrong")")
        } catch {
            results.set("u26", .fail, "Maintenance check failed: \(error.localizedDescription)")
        }
    }
}
