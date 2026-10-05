import CorckieCore
import Foundation

/// M2: synthetic routes for the simulator and the route tests (TESTING §4). A made-up street grid in metres around the
/// fake origin the other synthetic rides use (10.0 N, 30.0 W, open sea): **no real coordinates anywhere**. A trip drives a
/// path at a cruise speed with GPS jitter, a gentle climb for the barometer and a battery that runs down, then the scooter
/// switches itself off (0x80), so every trip is one ride. Trips of a series are 15 min apart (longer than "Same ride?").
public enum SyntheticRoutes {
    public static let originLat = 10.0
    public static let originLon = -30.0
    static let mPerDegLat = 111_195.0

    public typealias XY = (x: Double, y: Double)

    /// A to B, the usual way (about 3.7 km, a quarter of an hour at walking-plus pace is not needed: 9 min at 25 km/h)
    public static let main: [XY] = [(0, 0), (0, 700), (600, 1100), (1400, 1100), (1400, 1900), (2000, 2300)]
    /// A to B by another street in the middle (about 4.4 km); the same start and end
    public static let detour: [XY] = [(0, 0), (0, 700), (-300, 1250), (-300, 1900), (1400, 1900), (2000, 2300)]
    /// Round the block: ends 28 m from where it started (a loop is not a route)
    public static let loop: [XY] = [(0, 0), (0, 700), (700, 700), (700, 0), (20, 20)]

    public static func reversed(_ path: [XY]) -> [XY] { Array(path.reversed()) }

    public static func offset(_ path: [XY], by o: XY) -> [XY] { path.map { (x: $0.x + o.x, y: $0.y + o.y) } }

    /// Local metres on the fake map to latitude / longitude
    public static func coordinate(_ p: XY) -> (lat: Double, lon: Double) {
        let lat = originLat + p.y / mPerDegLat
        let lon = originLon + p.x / (mPerDegLat * cos(originLat * Double.pi / 180))
        return (lat, lon)
    }

    public static func pathLength(_ path: [XY]) -> Double {
        var total = 0.0
        if path.count < 2 { return 0 }
        for i in 1..<path.count { total += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y) }
        return total
    }

    /// The point `d` metres along the path
    public static func point(on path: [XY], at d: Double) -> XY {
        var left = d
        for i in 1..<path.count {
            let dx = path[i].x - path[i - 1].x
            let dy = path[i].y - path[i - 1].y
            let len = hypot(dx, dy)
            if left <= len || i == path.count - 1 {
                let f = len > 0 ? min(1, left / len) : 0
                return (x: path[i - 1].x + dx * f, y: path[i - 1].y + dy * f)
            }
            left -= len
        }
        return path[path.count - 1]
    }

    public struct Trip {
        public var stream: SimStream
        /// Seconds from the first sample to the last
        public var endT: Double
        public var endOdometerKm: Double
    }

    /// One trip along `path`: speeds up at 1.2 m/s², cruises, brakes at 1 m/s² to stop at the end, stands 10 s, the scooter
    /// switches off (0x80). GPS jitter is deterministic for a seed.
    public static func trip(path: [XY], cruiseKmh: Double = 25, seed: UInt64 = 1, jitterM: Double = 3, batteryStart: Int = 90,
                            usedPct: Int = 6, climbM: Double = 30, odometerKm: Double = 100) -> Trip {
        let total = pathLength(path)
        var rng = SplitMix64(seed: seed)
        let cruise = cruiseKmh / 3.6
        var samples: [MergedSample] = []
        var d = 0.0
        var speed = 0.0
        var odometer = odometerKm
        var t = 0

        func sample(_ t: Int, _ d: Double, _ speed: Double) -> MergedSample {
            let p = point(on: path, at: d)
            let jx = (rng.nextUnit() - 0.5) * 2 * jitterM
            let jy = (rng.nextUnit() - 0.5) * 2 * jitterM
            let c = coordinate((x: p.x + jx, y: p.y + jy))
            let used = total > 0 ? Int((Double(usedPct) * d / total).rounded()) : 0
            return MergedSample(t: Double(t), lat: c.lat, lon: c.lon, gpsSpeedKmh: speed * 3.6, scooterSpeedKmh: speed * 3.6,
                                elevBaroM: total > 0 ? climbM * sin(Double.pi * d / total) : 0, voltage: 50,
                                currentA: speed > 0.3 ? 8 : 0, batteryPct: batteryStart - used, temperatureC: 30,
                                brake: false, headlight: false, odometerKm: (odometer * 10).rounded() / 10)
        }

        samples.append(sample(0, 0, 0))
        while d < total - 0.5 && t < 4_000 {
            t += 1
            let remaining = total - d
            speed = min(cruise, speed + 1.2, (2 * remaining).squareRoot())
            speed = max(speed, 0.8)
            let step = min(speed, remaining)
            d += step
            odometer += step / 1000
            samples.append(sample(t, d, speed))
        }
        for _ in 0..<10 {
            t += 1
            samples.append(sample(t, d, 0))
        }
        let raw = SimStream(scooter: PacketEncoder.events(from: samples), phone: PhoneSource.events(fromMerged: samples))
        let stream = raw.applying([.shutdown(at: Double(t) - 2)])
        return Trip(stream: stream, endT: Double(t), endOdometerKm: odometer)
    }

    public struct Leg {
        public var path: [XY]
        public var cruiseKmh: Double
        /// GPS lost from / to (seconds from this trip's start)
        public var gpsLoss: (from: Double, to: Double)?
        /// Battery % the trip uses
        public var usedPct: Int

        public init(_ path: [XY], cruiseKmh: Double = 25, gpsLoss: (from: Double, to: Double)? = nil, usedPct: Int = 6) {
            self.usedPct = usedPct
            self.path = path
            self.cruiseKmh = cruiseKmh
            self.gpsLoss = gpsLoss
        }
    }

    /// Trips one after the other, `gapS` apart (15 min: longer than the 10 min of "Same ride?"). The battery runs down 6% per trip.
    public static func series(_ legs: [Leg], gapS: Double = 900, startBattery: Int = 90, floor: Int = 20) -> SimStream {
        var scooter: [TimedScooterEvent] = []
        var phone: [TimedPhoneEvent] = []
        var clock = 0.0
        var odometer = 100.0
        var battery = startBattery
        for (i, leg) in legs.enumerated() {
            let r = trip(path: leg.path, cruiseKmh: leg.cruiseKmh, seed: UInt64(7 + i), batteryStart: battery, usedPct: leg.usedPct, odometerKm: odometer)
            var piece = r.stream
            if let loss = leg.gpsLoss { piece = piece.applying([.gpsLoss(from: loss.from, to: loss.to)]) }
            let moved = SyntheticScenario.shifted(piece, by: clock)
            scooter += moved.scooter
            phone += moved.phone
            clock += r.endT + gapS
            odometer = r.endOdometerKm + 0.1
            battery = max(floor, battery - leg.usedPct)
        }
        return SimStream(scooter: scooter, phone: phone)
    }

    /// The same commute `count` times, each a little different in pace (24-26 km/h)
    public static func commute(_ count: Int, path: [XY] = main) -> SimStream {
        series((0..<count).map { Leg(path, cruiseKmh: 24 + Double($0 % 3)) })
    }

    public static let scenarios: [SyntheticScenario] = [
        SyntheticScenario(id: "ROUTE-COMMUTE", title: "Routes: the same commute 3 times (A to B)") { commute(3) },
        SyntheticScenario(id: "ROUTE-COMMUTE-6", title: "Routes: the same commute 6 times (for the route card)") { commute(6) },
        SyntheticScenario(id: "ROUTE-VARIANT", title: "Routes: twice the usual way, then a detour") {
            series([Leg(main, cruiseKmh: 25), Leg(main, cruiseKmh: 26), Leg(detour, cruiseKmh: 25)])
        },
        SyntheticScenario(id: "ROUTE-THEREBACK", title: "Routes: there and back, twice (A to B, B to A)") {
            series([Leg(main), Leg(reversed(main)), Leg(main, cruiseKmh: 26), Leg(reversed(main), cruiseKmh: 24)])
        },
        SyntheticScenario(id: "ROUTE-LOOP", title: "Routes: round the block twice (a loop is never a route)") {
            series([Leg(loop), Leg(loop, cruiseKmh: 26)])
        },
        SyntheticScenario(id: "ROUTE-NOGPS", title: "Routes: the second trip has no GPS at the start") {
            series([Leg(main), Leg(main, cruiseKmh: 26, gpsLoss: (from: 0, to: 150))])
        },
        SyntheticScenario(id: "ROUTE-GPSLOSS", title: "Routes: three known trips, the fourth loses GPS for 5 min (dot keeps moving)") {
            series([Leg(main), Leg(main, cruiseKmh: 26), Leg(main, cruiseKmh: 24),
                    Leg(main, cruiseKmh: 25, gpsLoss: (from: 90, to: 400))])
        },
        SyntheticScenario(id: "ROUTE-LOWBATT", title: "Routes: 6 trips each way, ending at 10% (greyed routes, there-and-back)") {
            // A to B uses 3%, B to A uses 6%: the last trip ends at 10%, so A to B still fits (needs 3.3 + 5) but not the round trip
            // (3.3 + 6.6 + 5 = 14.9), and B to A does not fit at all (6.6 + 5 = 11.6)
            var legs: [Leg] = []
            for i in 0..<6 {
                legs.append(Leg(main, cruiseKmh: 24 + Double(i % 3), usedPct: 3))
                legs.append(Leg(reversed(main), cruiseKmh: 24 + Double(i % 3), usedPct: 6))
            }
            return series(legs, startBattery: 64, floor: 0)
        }
    ]
}
