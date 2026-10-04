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
                       currentA: (Double) -> Double, batteryPct: (Double) -> Int = { _ in 90 },
                       startLat: Double = 10.0, startOdometerKm: Double = 100.0) -> SimStream {
        piece(seconds: seconds, scooterKmh: scooterKmh, gpsKmh: gpsKmh, currentA: currentA, batteryPct: batteryPct,
              startLat: startLat, startOdometerKm: startOdometerKm).stream
    }

    /// `stream` plus where the piece ends (latitude, odometer), so a second piece can carry on from there.
    static func piece(seconds: Int, scooterKmh: (Double) -> Double, gpsKmh: (Double) -> Double,
                      currentA: (Double) -> Double, batteryPct: (Double) -> Int = { _ in 90 },
                      startLat: Double = 10.0, startOdometerKm: Double = 100.0) -> (stream: SimStream, endLat: Double, endOdometerKm: Double) {
        var samples: [MergedSample] = []
        var lat = startLat
        var odometer = startOdometerKm
        for i in 0...seconds {
            let t = Double(i)
            let spd = scooterKmh(t), gps = gpsKmh(t)
            if i > 0 {
                lat += gps / 3.6 / 111_320
                odometer += spd / 3600
            }
            samples.append(MergedSample(t: t, lat: lat, lon: -30.0, gpsSpeedKmh: gps, scooterSpeedKmh: spd, elevBaroM: 0,
                                        voltage: 50, currentA: currentA(t), batteryPct: batteryPct(t), temperatureC: 30,
                                        brake: false, headlight: false, odometerKm: (odometer * 10).rounded() / 10))
        }
        let stream = SimStream(scooter: PacketEncoder.events(from: samples), phone: PhoneSource.events(fromMerged: samples))
        return (stream, lat, odometer)
    }

    /// The scooter goes silent at `at` (link lost, e.g. the scooter powers off without 0x80: CBError 6); the phone keeps going.
    static func cutScooter(_ s: SimStream, at: Double) -> SimStream {
        SimStream(scooter: s.scooter.filter { $0.t < at } + [TimedScooterEvent(t: at, event: .disconnected)], phone: s.phone)
    }

    /// Everything `dt` seconds later (scooter events, fixes and barometer readings).
    static func shifted(_ s: SimStream, by dt: Double) -> SimStream {
        let phone = s.phone.map { e -> TimedPhoneEvent in
            var out = TimedPhoneEvent(t: e.t + dt, event: e.event)
            if case .fix(var f) = e.event {
                f.t += dt
                out.event = .fix(f)
            } else if case .baro(var b) = e.event {
                b.t += dt
                out.event = .baro(b)
            }
            return out
        }
        return SimStream(scooter: s.scooter.map { TimedScooterEvent(t: $0.t + dt, event: $0.event) }, phone: phone)
    }

    /// M1-04 end-rule scenarios: ride 2 min at 25 km/h, stop at 135 s
    static let rideThenStop: [(t: Double, kmh: Double)] = [(0, 0), (5, 25), (125, 25), (135, 0)]
    static func rideThenStopStream(seconds: Int) -> SimStream {
        stream(seconds: seconds, scooterKmh: { linear(rideThenStop, at: $0) }, gpsKmh: { linear(rideThenStop, at: $0) },
               currentA: { $0 < 133 ? 10 : 0 })
    }

    /// D3 check: battery empty → push 1 km. 2 km at 25 km/h with the battery running down 20 → 3%, the motor stops
    /// at ~295 s, then 12 min of pushing at 5 km/h (1 km), then standing.
    static let pushProfile: [(t: Double, kmh: Double)] = [(0, 0), (5, 25), (290, 25), (300, 5), (1020, 5), (1030, 0)]

    /// Same ride: switched off at a light (0x80) after 2 min, back on 2 min later at the same place, riding on.
    static func sameRideStream() -> SimStream {
        let a = piece(seconds: 150, scooterKmh: { linear(rideThenStop, at: $0) }, gpsKmh: { linear(rideThenStop, at: $0) },
                      currentA: { $0 < 133 ? 10 : 0 })
        let first = a.stream.applying([.shutdown(at: 145)])
        let b = piece(seconds: 200, scooterKmh: { linear(rideThenStop, at: $0) }, gpsKmh: { linear(rideThenStop, at: $0) },
                      currentA: { $0 < 133 ? 10 : 0 }, startLat: a.endLat, startOdometerKm: a.endOdometerKm)
        let second = shifted(b.stream, by: 270)
        return SimStream(scooter: first.scooter + second.scooter, phone: first.phone + second.phone)
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
        },
        // M1-04 / SC-02: ride, stop, the scooter drops for good while standing; GPS still → ends by A at the last movement
        SyntheticScenario(id: "END-A", title: "End A: stop, then the scooter drops while standing") {
            SyntheticScenario.cutScooter(SyntheticScenario.rideThenStopStream(seconds: 300), at: 155)
        },
        // Auto-off after ~5 min standing, seen as a plain disconnect (CBError 6, no 0x80)
        SyntheticScenario(id: "AUTO-OFF", title: "Auto-off: 5 min standing, then the scooter goes (no 0x80)") {
            SyntheticScenario.cutScooter(SyntheticScenario.rideThenStopStream(seconds: 520), at: 435)
        },
        // M1-04 / T8 / A2: the scooter switches itself off (0x80) while standing → the ride ends at once
        SyntheticScenario(id: "OFF-0x80", title: "Scooter switches itself off (0x80) after a stop") {
            SyntheticScenario.rideThenStopStream(seconds: 200).applying([.shutdown(at: 150)])
        },
        // M1-04 / C: standing 11 min with the scooter on and connected
        SyntheticScenario(id: "STANDSTILL-10", title: "Standstill 11 min, scooter on") {
            SyntheticScenario.rideThenStopStream(seconds: 800)
        },
        // M1-04 / D3: battery empty, push 1 km (walking stretch, "battery ran out at 3%")
        SyntheticScenario(id: "PUSH-1KM", title: "Battery empty → push 1 km") {
            SyntheticScenario.stream(seconds: 1_100, scooterKmh: { SyntheticScenario.linear(SyntheticScenario.pushProfile, at: $0) }, gpsKmh: { SyntheticScenario.linear(SyntheticScenario.pushProfile, at: $0) },
                   currentA: { $0 < 295 ? 12 : 0 }, batteryPct: { $0 < 300 ? Int(20 - 17 * $0 / 300) : 3 })
        },
        // M1-04 / T21: off at a light and on again within 10 min and 200 m → "Same ride?"
        SyntheticScenario(id: "SAME-RIDE", title: "Same ride: off at a light, on again 2 min later") {
            SyntheticScenario.sameRideStream()
        }
    ]
}
