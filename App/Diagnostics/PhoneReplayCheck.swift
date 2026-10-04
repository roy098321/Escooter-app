import CorckieCore
import CorckieSim
import Foundation

/// u3 (M1-02): the fake scooter replays the phone's GPS and barometer of ride 2 (F4) on the
/// scooter's clock (F3). Runs in a blink on the bundled fixtures, with no timers.
enum PhoneReplayCheck {
    static func run() {
        let results = CheckResults.shared
        func text(_ name: String) -> String? {
            Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let f3 = text("F3_ride2_merged"), let loc = text("F4_ride2_location"), let baro = text("F4_ride2_barometer"),
              let fixture = SimFixture.all.first(where: { $0.id == "F3" }) else {
            results.set("u3", .fail, "Ride-2 fixtures not found in the app")
            return
        }
        do {
            guard let start = LogReader.mergedStartTimeOfDayS(f3) else {
                results.set("u3", .fail, "F3 has no start time")
                return
            }
            let samples = try LogReader.mergedSamples(f3)
            let stream = SimStream(scooter: try fixture.events(from: f3),
                                   phone: try PhoneSource.events(locationText: loc, barometerText: baro, scooterStartTimeOfDayS: start))
            let session = ReplaySession(stream: stream, speed: 50)
            let all = session.runToEndAll()
            var distances: [Double] = []
            for event in all.phone {
                guard let fix = event.fix, fix.t >= 0, Int(fix.t.rounded()) < samples.count,
                      let lat = samples[Int(fix.t.rounded())].lat, let lon = samples[Int(fix.t.rounded())].lon else { continue }
                let dLat = (fix.lat - lat) * 111_320
                let dLon = (fix.lon - lon) * 111_320 * cos(lat * .pi / 180)
                distances.append((dLat * dLat + dLon * dLon).squareRoot())
            }
            let fixes = all.phone.filter { $0.fix != nil }.count
            let readings = all.phone.filter { $0.baro != nil }.count
            let mean = distances.isEmpty ? .infinity : distances.reduce(0, +) / Double(distances.count)
            let ok = session.isFinished && fixes > 1_700 && readings > 1_000 && mean <= 5
            results.set("u3", ok ? .pass : .fail,
                        String(format: "%d GPS fixes + %d barometer readings replayed; phone track %.1f m from the scooter log", fixes, readings, mean))
        } catch {
            results.set("u3", .fail, "Replay failed: \(error.localizedDescription)")
        }
    }
}
