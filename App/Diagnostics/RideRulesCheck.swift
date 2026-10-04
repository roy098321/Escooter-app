import CorckieCore
import Foundation

/// u6 (M1-07): the live-view safety rules and the message budget, run on a made-up ride: SLOW above 45 / clears
/// below 43 (scooter and GPS speed), GPS speed labelled, banners locked at 5 km/h and above, at most 2 at ride
/// start, hot once and very hot until it cools, "Going for a ride?" once across three reconnect blips.
enum RideRulesCheck {
    static func run() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }

        // SLOW
        var live = LiveStateBuilder()
        let seq: [Double] = [44.9, 45.1, 43.0, 42.9]
        let slow = seq.map { live.update(LiveInput(scooterSpeedKmh: $0)).slow }
        expect(slow == [false, true, true, false], "SLOW on at 45.1, off at 42.9 (scooter)")
        var gpsLive = LiveStateBuilder()
        let gps = gpsLive.update(LiveInput(gpsSpeedKmh: 46, scooterLinked: false))
        expect(gps.slow && gps.speedLabel == "GPS", "SLOW + GPS label on GPS speed")
        expect(gpsLive.update(LiveInput(gpsSpeedKmh: 4, scooterLinked: false)).speedKmh == 0, "GPS under 5 km/h shows 0")

        // banners
        var q = BannerQueue()
        q.beginRide(messages: [.headwind, .destination, .batteryTight, .sameRide])
        expect(q.droppedToSummary.count == 2, "ride start: 2 shown, 2 to the summary")
        let first = q.tick(at: 0, speedKmh: 0)
        expect(first?.banner == .batteryTight && first?.tappable == true, "highest priority first, tappable when stopped")
        expect(q.tick(at: 1, speedKmh: 5.1)?.tappable == false, "locked at 5.1 km/h")
        expect(q.tick(at: 8, speedKmh: 0)?.banner == .sameRide, "next one after 8 s")
        q.beginRide(messages: [])
        q.feedHeat(tempC: 91, at: 0)
        q.feedHeat(tempC: 101, at: 5)
        q.feedHeat(tempC: 95, at: 10)
        expect(q.tick(at: 60, speedKmh: 20)?.banner == .veryHot, "very hot stays until below hot")
        q.feedHeat(tempC: 85, at: 70)
        expect(q.tick(at: 70, speedKmh: 20) == nil, "...then goes")

        // going for a ride
        var rule = GoingForARideRule()
        var sent = 0
        func count(_ out: [GoingForARideOutput]) {
            for o in out { if case .send = o { sent += 1 } }
        }
        count(rule.scooterConnected(at: 0, appActive: false, rideActive: false))
        count(rule.batteryReading(pct: 90, at: 1, appActive: false, rideActive: false))
        for t in [30.0, 90.0, 150.0] {
            rule.scooterDisconnected(at: t)
            count(rule.scooterConnected(at: t + 20, appActive: false, rideActive: false))
            count(rule.batteryReading(pct: 90, at: t + 21, appActive: false, rideActive: false))
        }
        expect(sent == 1, "one notification across 3 reconnect blips")
        let removed = rule.rideStarted(at: 200)
        expect(removed == [.remove(reason: "ride started")], "removed when the ride starts")

        CheckResults.shared.set("u6", ok ? .pass : .fail, notes.joined(separator: " · "))
    }
}
