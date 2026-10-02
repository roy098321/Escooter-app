import Foundation

/// The first ride numbers the foundation needs to prove a replay end to end (TESTING §2
/// golden values). The full metrics (M4–M10 with stops, gaps, calibration) arrive in P5.
public struct RideTotals: Sendable {
    /// M8 raw energy, Wh: Σ voltage × current × Δt over packet B, Δt ≤ 2 s · CALC_SPEC §3 M8
    public private(set) var energyWhRaw = 0.0
    /// M5 distance from the odometer (first and last valid reading), km · CALC_SPEC §3 M5
    public private(set) var odometerStartKm: Double?
    public private(set) var odometerEndKm: Double?
    /// M7 top speed held ≥ T33 (1 s), km/h · CALC_SPEC §3 M7
    public private(set) var topSpeedKmh = 0.0
    /// M38 temperatures, °C · CALC_SPEC §7 M38
    public private(set) var temperatureStartC: Double?
    public private(set) var temperaturePeakC: Double?
    public private(set) var noReadingTemperaturePackets = 0
    /// Battery %: first and last valid reading
    public private(set) var batteryStartPct: Int?
    public private(set) var batteryEndPct: Int?
    /// Seen during the ride
    public private(set) var gearCaps: Set<Int> = []
    public private(set) var lowestMovingSpeedKmh: Double?
    /// Time of the first 0x80 "shutting down" flag
    public private(set) var shutdownAt: Double?

    private var lastEnergyT: Double?
    private var recentSpeeds: [(t: Double, kmh: Double)] = []

    public init() {}

    public var distanceKm: Double {
        guard let a = odometerStartKm, let b = odometerEndKm else { return 0 }
        return b - a
    }

    public var temperatureRiseC: Double? {
        guard let a = temperatureStartC, let p = temperaturePeakC else { return nil }
        return p - a
    }

    /// Adds one checked frame. `kind` says which packet made it.
    public mutating func add(_ f: ScooterFrame, kind: FrameAssembler.Kind) {
        switch kind {
        case .a:
            if let km = f.odometerKm {
                if odometerStartKm == nil { odometerStartKm = km }
                odometerEndKm = km
            }
            if let pct = f.batteryPct {
                if batteryStartPct == nil { batteryStartPct = pct }
                batteryEndPct = pct
            }
            if let cap = f.capKmh { gearCaps.insert(cap) }
            if f.shuttingDown, shutdownAt == nil { shutdownAt = f.t }
            if let v = f.speedKmh {
                if v > 0 { lowestMovingSpeedKmh = min(lowestMovingSpeedKmh ?? v, v) }
                addSpeed(t: f.t, kmh: v)
            }
        case .b:
            if f.temperatureC == nil, (f.ageB ?? 99) == 0 { noReadingTemperaturePackets += 1 }
            if let c = f.temperatureC {
                if temperatureStartC == nil { temperatureStartC = c }
                temperaturePeakC = max(temperaturePeakC ?? c, c)
            }
            if let p = f.powerW {
                if let last = lastEnergyT, f.t - last > 0, f.t - last <= 2 {
                    energyWhRaw += p * (f.t - last) / 3600
                }
                lastEnergyT = f.t
            }
        }
    }

    /// M7: the highest speed the scooter held for at least T33 (1 s): the minimum of a window
    /// that spans ≥ 1 s, maximised over all windows.
    private mutating func addSpeed(t: Double, kmh: Double) {
        recentSpeeds.append((t, kmh))
        while recentSpeeds.count > 1, t - recentSpeeds[1].t >= T.t33TopSpeedHeldS { recentSpeeds.removeFirst() }
        guard let first = recentSpeeds.first, t - first.t >= T.t33TopSpeedHeldS else { return }
        let held = recentSpeeds.map { $0.kmh }.min() ?? 0
        topSpeedKmh = max(topSpeedKmh, held)
    }

    /// Note a missing stretch (disconnect): energy and the held-speed window restart.
    public mutating func gap() {
        lastEnergyT = nil
        recentSpeeds.removeAll()
    }
}
