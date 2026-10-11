import CorckieCore
import Foundation

/// u47: the prediction log on a temporary database: estimates shown, the ride closes, the actual numbers are filled in, accuracy.txt reads them.
enum AccuracyCheck {
    static func run() {
        var detail = "-"
        var ok = false
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let start = Int64(Date().timeIntervalSince1970 * 1000) - 7_200_000
            try RideToolsSeed.ride(temp, id: "A1", startAt: start)
            try temp.writer.write { db in
                try db.execute(sql: """
                    UPDATE ride SET routeId = 'RT', startRestPct = 80, endRestPct = 74, energyWhRaw = 50, totalS = 600, distanceM = 6000,
                                    usedPct = 6, isSimulated = 0 WHERE id = 'A1'
                    """)
            }
            let store = PredictionQueries(temp)
            let first = try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 570, at: start - 60_000)
            let again = try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 570, at: start - 30_000)
            _ = try store.log(kind: PredictionKind.battery, routeId: "RT", predicted: 5, at: start - 60_000)
            _ = try store.log(kind: PredictionKind.range, routeId: nil, predicted: 90, aux: 75, at: start + 10_000)
            _ = try store.log(kind: PredictionKind.eta50, routeId: "RT", predicted: Double(start + 300_000), at: start + 300_000)
            _ = try store.log(kind: PredictionKind.time, routeId: "OTHER", predicted: 100, at: start - 60_000)
            try FieldKitService.afterRide(temp, rideId: "A1", nowMs: start + 700_000)
            let rows = FieldKitService.accuracyRows(temp)
            func actual(_ kind: String) -> Double? { rows.first { $0.kind == kind }?.actual }
            let timeLine = FieldKitService.accuracyLines(temp).first { $0.kind == PredictionKind.time }
            let text = FieldKitService.accuracyText(temp)
            let waiting = try store.waiting().count
            let a = first && !again
            let b = actual(PredictionKind.time) == 600 && actual(PredictionKind.battery) == 6 && actual(PredictionKind.eta50) != nil
            let c = abs((actual(PredictionKind.range) ?? 0) - 75) < 1e-6 && abs((timeLine?.median ?? 0) - 0.5) < 1e-6
            let d = waiting == 1 && text.contains("Q-C Today's time estimate") && text.contains("Q-F Real range")
            ok = a && b && c && d
            detail = "dedupe \(a ? "ok" : "wrong") · actual numbers \(b ? "ok" : "wrong") · range / median \(c ? "ok" : "wrong") · accuracy.txt \(d ? "ok" : "wrong")"
        } catch {
            detail = error.localizedDescription
        }
        CheckResults.shared.set("u47", ok ? .pass : .fail, detail)
    }
}

/// u48: shadow thresholds on a temporary database: what 48 km/h (and the other values) would have decided, written to shadow.txt.
enum ShadowCheck {
    static func run() {
        var detail = "-"
        var ok = false
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let start = Int64(Date().timeIntervalSince1970 * 1000) - 7_200_000
            try RideToolsSeed.ride(temp, id: "S1", startAt: start)
            try temp.writer.write { db in
                // one sample at 45.4 km/h: SLOW comes on at 45, not at 48
                try db.execute(sql: "UPDATE ride_sample SET speedMps = 12.6 WHERE rideId = 'S1' AND t = 50000")
                try db.execute(sql: "UPDATE ride SET isSimulated = 0 WHERE id = 'S1'")
            }
            try FieldKitService.afterRide(temp, rideId: "S1", nowMs: start + 700_000)
            let rows = try PredictionQueries(temp).shadowRows()
            let slow48 = rows.first { $0.rule == ShadowCalc.ruleSlow && $0.variant == "48 km/h" }
            let a = slow48?.differs == true && slow48?.decision == "0 warnings"
            let text = FieldKitService.shadowText(temp)
            let b = text.contains("48 km/h: 1 rides, decided differently in 1") && text.contains("Ride end after standing still")
            let c = rows.contains { $0.rule == ShadowCalc.ruleEnd } && rows.contains { $0.rule == ShadowCalc.ruleStart }
            ok = a && b && c
            detail = "SLOW 48 \(a ? "ok" : "wrong") · shadow.txt \(b ? "ok" : "wrong") · end and autostart rules \(c ? "ok" : "wrong")"
        } catch {
            detail = error.localizedDescription
        }
        CheckResults.shared.set("u48", ok ? .pass : .fail, detail)
    }
}

/// u49: the scenario list ticks itself: one made-up night / rain / low-battery / heavy / GPS-loss / left-on / Low Power / charged / pocket ride.
enum ScenarioCheck {
    static func run() {
        var detail = "-"
        var ok = false
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let start = (now / 86_400_000 - 1) * 86_400_000 + 19 * 3_600_000          // 19:00 UTC = 22:00 at +03:00
            try RideToolsSeed.ride(temp, id: "C1", startAt: start)
            try temp.writer.write { db in
                try db.execute(sql: """
                    UPDATE ride SET isSimulated = 0, wet = 'rain', startRestPct = 15, loadKg = 15, gapGpsS = 30, endReason = 'standstill',
                                    totalS = 495, distanceM = 2500 WHERE id = 'C1'
                    """)
                try db.execute(sql: "INSERT INTO charge (id, afterRideId) VALUES ('ch1', 'C1')")
            }
            RideMarks.noteTrackingStarted(temp, at: start - 1_000)
            RideMarks.add(temp, RideMarks.lowPower, at: start + 5_000)
            let ticked = Set(FieldKitService.scenarioVerdicts(temp).map(\.id))
            let all = Set(ScenarioRules.ids)
            // a screen-on mark during the ride takes the pocket tick away again
            RideMarks.add(temp, RideMarks.screenOn, at: start + 90_000)
            let withScreen = Set(FieldKitService.scenarioVerdicts(temp).map(\.id))
            let a = ticked == all
            let b = withScreen == all.subtracting(["p6pocket"])
            ok = a && b
            detail = "\(ticked.count) of \(all.count) scenarios ticked by the made-up ride\(a ? "" : " (missing: \(all.subtracting(ticked).sorted().joined(separator: ", ")))") · screen-on mark clears the pocket tick \(b ? "ok" : "wrong")"
        } catch {
            detail = error.localizedDescription
        }
        CheckResults.shared.set("u49", ok ? .pass : .fail, detail)
    }
}

/// Real rides tick the P6 scenario checks (called when a ride closes, in Run all automatic and at export).
enum ScenarioChecks {
    static func run(database: AppDatabase?) {
        guard let database else { return }
        for verdict in FieldKitService.scenarioVerdicts(database) where verdict.result == .pass {
            CheckResults.shared.passOnce(verdict.id, verdict.note)
        }
    }
}
