import Foundation
@testable import CorckieCore

/// Hotfix 03: a made-up 10 km route due north (not a real place) and made-up rides on it, one reading a second.
enum H3Fix {
    static let km = 10.0
    static let volts = 50.0
    static let t0 = 1_000_000.0

    static func point(_ m: Double) -> GeoPoint { GeoPoint(lat: 10 + m / Geo.mPerDegLat, lon: -30) }
    static var path: [GeoPoint] { stride(from: 0.0, through: km * 1000, by: 100).map { point($0) } }

    static func follower(todayS: Double = 1_440, history: RouteHistory? = nil) -> RouteFollower {
        var f = RouteFollower(destinationName: "Uni", path: path, todayS: todayS)!
        f.history = history
        return f
    }

    /// - pctPerKm: the TRUE battery use at each km; sag(t, km): points the scooter's own % reads low at that moment (under load)
    /// - stops: (at metres, seconds) standing still; slowFrom: from this km on, ride at `slowKmh`
    static func ride(startPct: Double = 90, whPerPct: Double = 8.1, speedKmh: Double = 25, pctPerKm: @escaping (Double) -> Double = { _ in 2 },
                     stops: [(atM: Double, s: Double)] = [], sag: @escaping (Double, Double) -> Double = { _, _ in 0 }, withPower: Bool = true,
                     slowFrom: Double = 99, slowKmh: Double = 25, standBeforeS: Double = 10, standAfterS: Double = 60) -> [RouteHistorySample] {
        var out: [RouteHistorySample] = []
        var t = 0.0
        var d = 0.0
        var used = 0.0
        var pending = stops.sorted { $0.atM < $1.atM }
        var stopLeft = 0.0
        func reading(_ speed: Double, _ power: Double) {
            let pct = (startPct - used - sag(t, d / 1000)).rounded()
            out.append(RouteHistorySample(t: t0 + t, lat: point(d).lat, lon: -30, speedKmh: speed, batteryPct: pct,
                                          powerW: withPower ? power : nil, currentA: withPower ? power / volts : nil))
        }
        for _ in 0..<Int(standBeforeS) { reading(0, 0); t += 1 }
        while d < km * 1000 {
            if stopLeft > 0 {
                reading(0, 0)
                stopLeft -= 1
                t += 1
                continue
            }
            if let s = pending.first, d >= s.atM { stopLeft = s.s; pending.removeFirst(); continue }
            let v = (d / 1000 >= slowFrom ? slowKmh : speedKmh) / 3.6
            let step = min(v, km * 1000 - d)
            let pct = pctPerKm(d / 1000) * step / 1000
            used += pct
            d += step
            reading(v * 3.6, pct * whPerPct * 3600)
            t += 1
        }
        for _ in 0..<Int(standAfterS) { reading(0, 0); t += 1 }
        return out
    }

    /// `n` past rides on the route, each using `pct` %/km in `s` seconds (evenly)
    static func history(rides n: Int = 3, pctPerKm: Double = 2, todayS: Double = 1_440, whPerPct: Double = 8.1) -> RouteHistory {
        let speed = km * 3600 / todayS
        let one = RouteRideProfile.make(samples: ride(speedKmh: speed, pctPerKm: { _ in pctPerKm }), route: follower(todayS: todayS),
                                        whPerPct: whPerPct)!
        return RouteHistory(rides: Array(repeating: one, count: n), routeKm: km)
    }
}
