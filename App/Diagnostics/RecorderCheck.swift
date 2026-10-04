import CorckieCore
import CorckieSim
import Foundation

/// u12 (M1-09): the Recorder end to end on the fake scooter: rides 1 and 2 go through the real Recorder actor
/// (ride engine, 5-s samples, raw packets, stops, ride row) into a temporary database and give the golden totals
/// (437 Wh / 16.3 km, 322 Wh / 13.7 km); then an app kill mid-ride is recovered from the saved state. The real
/// database is never touched (ride count before = after).
enum RecorderCheck {
    static func run(real: AppDatabase?) async {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        let realBefore = real.flatMap { try? RideQueries($0).rides(includeDiscarded: true).count }
        let base = Date().timeIntervalSince1970 - 86_400
        for (id, wh, km) in [("F2", 437.0, 16.3), ("F5", 322.0, 13.7)] {
            guard let fixture = SimFixture.all.first(where: { $0.id == id }),
                  let url = Bundle.main.url(forResource: fixture.fileName, withExtension: "csv", subdirectory: "Fixtures"),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let events = try? fixture.events(from: text) else {
                expect(false, "\(id): fixture missing")
                continue
            }
            guard let db = try? AppDatabase.openTemporary(build: AppInfo.build) else {
                expect(false, "\(id): temporary database did not open")
                continue
            }
            defer { db.discardTemporary() }
            let rec = Recorder(database: db, simulated: true, build: AppInfo.build, stateURL: Recorder.stateURL(for: db),
                               epochOffset: base - (events.first?.t ?? 0))
            await rec.process(RecorderRunner.inputs(SimStream(scooter: events, phone: [])))
            let ids = await rec.closedRideIds
            let q = RideQueries(db)
            guard let rideId = ids.first, let ride = try? q.ride(id: rideId) else {
                expect(false, "\(id): no ride closed")
                continue
            }
            let e = ride.energyWhRaw ?? 0
            let d = (ride.distanceM ?? 0) / 1000
            let samples = (try? q.sampleCount(rideId: rideId)) ?? 0
            let chunks = (try? q.chunks(rideId: rideId).count) ?? 0
            expect(abs(e - wh) <= wh * 0.03 && abs(d - km) <= 0.15 && ride.status == "ended",
                   String(format: "%@: %.0f Wh · %.1f km · ended by %@ · %ld samples · %ld raw chunks", id, e, d, ride.endReason ?? "?", samples, chunks))

            if id == "F5" {
                // App killed 15 min in and back 10 min later: closed as recovered at its last sample
                let inputs = RecorderRunner.inputs(SimStream(scooter: events, phone: []))
                let killAt = (inputs.first?.t ?? 0) + 900
                guard let db2 = try? AppDatabase.openTemporary(build: AppInfo.build) else { continue }
                defer { db2.discardTemporary() }
                let stateURL = Recorder.stateURL(for: db2)
                let first = Recorder(database: db2, simulated: true, build: AppInfo.build, stateURL: stateURL, epochOffset: base)
                await first.process(inputs.filter { $0.t < killAt })
                let second = Recorder(database: nil, simulated: true, build: AppInfo.build, stateURL: stateURL, epochOffset: base)
                await second.attach(db2, now: killAt + 600)
                let recovered = await second.closedRideIds.first.flatMap { try? RideQueries(db2).ride(id: $0) }
                expect(recovered?.status == "recovered", "killed mid-ride, back after 10 min: \(recovered?.status ?? "not closed")")
            }
        }
        let realAfter = real.flatMap { try? RideQueries($0).rides(includeDiscarded: true).count }
        expect(realBefore == realAfter, "real rides \(realBefore.map(String.init) ?? "?") before / \(realAfter.map(String.init) ?? "?") after")
        CheckResults.shared.set("u12", ok ? .pass : .fail, notes.joined(separator: " · "))
    }
}
