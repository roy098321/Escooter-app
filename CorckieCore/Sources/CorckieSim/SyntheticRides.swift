import CorckieCore
import Foundation

/// Synthetic rides for the scenarios no recorded ride covers (TESTING §4: SPD-46, TRAP-*).
/// Built as 1-per-second merged samples, so the same encoder and phone source as the real
/// fixtures turn them into packets and GPS fixes: nothing special-cased downstream.
public struct SyntheticScenario: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let build: @Sendable () -> SimStream

    /// Speed profile helper: linear between (t, km/h) points, last value held.
    static func linear(_ points: [(t: Double, kmh: Double)], at t: Double) -> Double {
        guard let first = points.first else { return 0 }
        if t <= first.t { return first.kmh }
        for i in 1..<points.count where t <= points[i].t {
            let a = points[i - 1], b = points[i]
            return a.kmh + (b.kmh - a.kmh) * (t - a.t) / max(1e-9, b.t - a.t)
        }
        return points[points.count - 1].kmh
    }

    /// One second per sample from 0 to `seconds`. GPS goes north from the fake origin at the GPS speed.
    static func stream(seconds: Int, scooterKmh: (Double) -> Double, gpsKmh: (Double) -> Double,
                       currentA: (Double) -> Double) -> SimStream {
        var samples: [MergedSample] = []
        var lat = 10.0
        var odometer = 100.0
        for i in 0...seconds {
            let t = Double(i)
            let spd = scooterKmh(t), gps = gpsKmh(t)
            if i > 0 {
                lat += gps / 3.6 / 111_320
                odometer += spd / 3600
            }
            samples.append(MergedSample(t: t, lat: lat, lon: -30.0, gpsSpeedKmh: gps, scooterSpeedKmh: spd, elevBaroM: 0,
                                        voltage: 50, currentA: currentA(t), batteryPct: 90, temperatureC: 30,
                                        brake: false, headlight: false, odometerKm: (odometer * 10).rounded() / 10))
        }
        return SimStream(scooter: PacketEncoder.events(from: samples), phone: PhoneSource.events(fromMerged: samples))
    }

    static let spd46Profile: [(t: Double, kmh: Double)] =
        [(0, 0), (30, 40), (36, 46), (40, 44), (44, 46), (52, 42), (70, 20), (90, 0)]
    static let spd46GpsProfile: [(t: Double, kmh: Double)] = [(0, 0), (30, 40), (45, 46), (130, 46)]
    static let kickProfile: [(t: Double, kmh: Double)] = [(0, 0), (5, 3), (14, 18), (60, 18)]

    public static let all: [SyntheticScenario] = [
        // M1-05 / T99: the scooter ramps 40 → 46 → 44 → 46 → 42 km/h; the warning must not flicker
        SyntheticScenario(id: "SPD-46", title: "Speed ramps 40 → 46 → 44 → 46 → 42 km/h") {
            SyntheticScenario.stream(seconds: 90, scooterKmh: { SyntheticScenario.linear(SyntheticScenario.spd46Profile, at: $0) },
                   gpsKmh: { SyntheticScenario.linear(SyntheticScenario.spd46Profile, at: $0) }, currentA: { $0 < 70 ? 18 : 3 })
        },
        // The scooter drops while GPS reads 46: the warning keeps working on the phone's speed
        SyntheticScenario(id: "SPD-46-GPS", title: "Disconnect while GPS reads 46 km/h") {
            SyntheticScenario.stream(seconds: 130, scooterKmh: { SyntheticScenario.linear(SyntheticScenario.spd46GpsProfile, at: $0) },
                   gpsKmh: { SyntheticScenario.linear(SyntheticScenario.spd46GpsProfile, at: $0) }, currentA: { _ in 20 })
                .applying([.disconnect(at: 70, durationS: 40)])
        },
        // T14 trap: walking the switched-on scooter, 5 km/h, no motor current, GPS walking
        SyntheticScenario(id: "TRAP-WALK", title: "Trap: walking the scooter (5 km/h, no current)") {
            SyntheticScenario.stream(seconds: 90, scooterKmh: { _ in 5 }, gpsKmh: { _ in 5 }, currentA: { _ in 0 })
        },
        // T14 trap: wheel spinning on the stand, 15 km/h, motor barely loaded, GPS still
        SyntheticScenario(id: "TRAP-SPIN", title: "Trap: wheel spinning on the stand (15 km/h, GPS still)") {
            SyntheticScenario.stream(seconds: 60, scooterKmh: { $0 < 5 ? 0 : 15 }, gpsKmh: { _ in 0 }, currentA: { $0 < 5 ? 0 : 0.3 })
        },
        // T14 trap: kick-start, motor current high and GPS above 8 km/h: the ride is real
        SyntheticScenario(id: "TRAP-KICK", title: "Trap: kick-start (current > 0.5 A, GPS > 8 km/h)") {
            SyntheticScenario.stream(seconds: 60, scooterKmh: { SyntheticScenario.linear(SyntheticScenario.kickProfile, at: $0) },
                   gpsKmh: { SyntheticScenario.linear(SyntheticScenario.kickProfile, at: $0) }, currentA: { $0 < 5 ? 0 : 12 })
        }
    ]
}
