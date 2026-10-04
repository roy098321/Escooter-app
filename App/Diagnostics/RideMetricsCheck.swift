import CorckieCore
import CorckieSim
import Foundation

/// u5 (M1-06): ride metrics computed from stored-style samples (one every 5 s, like the Recorder)
/// match the recorded rides: ride 1 = 437 Wh / 16.3 km, ride 2 = 322 Wh / 13.7 km. No timers, no scooter.
enum RideMetricsCheck {
    struct Outcome {
        var metrics: RideMetrics
        var samples: Int
    }

    static func metrics(fixture fileName: String) -> Outcome? {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "csv", subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let sim = SimFixture.all.first(where: { $0.fileName == fileName }),
              let events = try? sim.events(from: text) else { return nil }
        let startT = events.first?.t ?? 0
        var pipeline = ScooterPipeline()
        var sampler = RideSampler(intervalS: 5)
        var samples: [RideSample] = []
        for e in events {
            pipeline.handle(e)
            guard e.bytes != nil, let frame = pipeline.frame, frame.t == e.t else { continue }
            if let s = sampler.offer(frame, startT: startT) { samples.append(s) }
        }
        let m = RideMetricsCalculator.compute(samples, ignoredReadings: pipeline.plausibility.ignoredReadings)
        return Outcome(metrics: m, samples: samples.count)
    }

    static func run() {
        let results = CheckResults.shared
        guard let one = metrics(fixture: "F2_ride1_nrf"), let two = metrics(fixture: "F5_ride2_nrf") else {
            results.set("u5", .fail, "Ride fixtures not found in the app")
            return
        }
        let a = one.metrics, b = two.metrics
        let ok1 = abs(a.energyWhRaw - 437) <= 437 * 0.03 && abs(a.distanceKm - 16.3) <= 0.15
            && (40...51.7).contains(a.topSpeedKmh) && abs((a.tempPeakC ?? 0) - 92) <= 1
        let ok2 = abs(b.energyWhRaw - 322) <= 322 * 0.03 && abs(b.distanceKm - 13.7) <= 0.15
        results.set("u5", ok1 && ok2 ? .pass : .fail,
                    String(format: "Ride 1: %.0f Wh · %.1f km · top %.1f km/h · peak %.0f °C (%d samples). Ride 2: %.0f Wh · %.1f km (%d samples)",
                           a.energyWhRaw, a.distanceKm, a.topSpeedKmh, a.tempPeakC ?? 0, one.samples,
                           b.energyWhRaw, b.distanceKm, two.samples))
    }
}
