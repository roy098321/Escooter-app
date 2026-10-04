import Foundation

/// G1b plausibility filter + format-change watch · CALC_SPEC §2, thresholds T03–T07 (no fixed speed maximum: T02 retired, P4 D1 A2).
/// Runs on every frame before anything else. A dropped value becomes "missing" for that
/// frame; the rest of the frame is kept.
public struct Plausibility {
    public enum Field: String, CaseIterable, Sendable {
        case speed, battery, voltage, temperature, odometer
    }

    public struct Result: Sendable {
        public var frame: ScooterFrame
        public var dropped: [Field]
    }

    /// Total readings dropped (`ride.ignoredReadings`).
    public private(set) var ignoredReadings = 0
    /// The link is untrusted: banner "Scooter data format changed", phone mode (DEPENDENCIES #2).
    public private(set) var formatChanged = false
    public private(set) var formatChangeReason: String?
    /// The failed-share rule (> T07 of the frames over 60 s) tripped. The ride engine acts on this one only:
    /// "no packet A for 10 s" is already "scooter gone" there (connected but silent).
    public private(set) var failedShareTripped = false

    private var lastSpeed: (t: Double, kmh: Double)?
    private var lastBattery: (t: Double, pct: Int)?
    private var lastOdometer: (t: Double, km: Double)?
    private var window: [(t: Double, failed: Bool)] = []
    private var lastValidA: Double?
    /// The "no packet A" watch starts at the first packet after a connection, not at the
    /// connection itself: a link that hasn't subscribed yet is a connection problem (T100),
    /// not a data-format change.
    private var armedAt: Double?

    public init() {}

    /// Call when the scooter connects; the watch re-arms on the next packet.
    public mutating func connected(at t: Double) {
        // A new connection starts fresh: distance ridden without the phone is not a bad reading
        lastSpeed = nil
        lastBattery = nil
        lastOdometer = nil
        armedAt = nil
        lastValidA = nil
        window.removeAll()
    }

    /// Checks one frame. `isPacketA` = this frame was made by a packet A (fresh A fields).
    public mutating func check(_ input: ScooterFrame, isPacketA: Bool) -> Result {
        var f = input
        var dropped: [Field] = []
        let t = f.t
        if armedAt == nil { armedAt = t }

        if isPacketA {
            // Speed: only a step larger than T03 per second (no fixed maximum, P4 D1 A2)
            if let v = f.speedKmh {
                var bad = v < 0
                if !bad, let last = lastSpeed {
                    let dt = max(t - last.t, 0.001)
                    bad = abs(v - last.kmh) > T.t03MaxSpeedStepKmhPerS * max(dt, 1)
                }
                if bad { f.speedKmh = nil; dropped.append(.speed) } else { lastSpeed = (t, v) }
            }
            // Voltage outside the pack range (T05)
            if let volts = f.voltage, volts < T.t05MinVoltage || volts > T.t05MaxVoltage {
                f.voltage = nil
                dropped.append(.voltage)
            }
            // Battery %: more than T04 within 60 s while moving
            if let pct = f.batteryPct {
                var bad = pct < 0 || pct > 100
                let moving = (f.speedKmh ?? 0) > 0
                if !bad, moving, let last = lastBattery, t - last.t <= T.t04WindowS {
                    bad = Double(abs(pct - last.pct)) > T.t04MaxBatteryStepPct
                }
                if bad { f.batteryPct = nil; dropped.append(.battery) } else { lastBattery = (t, pct) }
            }
            // Odometer: backwards, or more than speed × time + 0.2 km
            if let km = f.odometerKm {
                var bad = false
                if let last = lastOdometer {
                    let maxKmh = max(f.speedKmh ?? 0, lastSpeed?.kmh ?? 0)
                    let allowed = maxKmh * max(t - last.t, 0) / 3600 + 0.2
                    bad = km < last.km || km - last.km > allowed
                }
                if bad { f.odometerKm = nil; dropped.append(.odometer) } else { lastOdometer = (t, km) }
            }
            if dropped.isEmpty { lastValidA = t }
        }
        // Temperature outside T06 (nil = "no reading", never dropped)
        if let c = f.temperatureC, c < T.t06MinTempC || c > T.t06MaxTempC {
            f.temperatureC = nil
            dropped.append(.temperature)
        }

        ignoredReadings += dropped.count
        record(t: t, failed: !dropped.isEmpty)
        return Result(frame: f, dropped: dropped)
    }

    /// Call regularly (every packet, or a 1 s tick) to run the "no packet A for 10 s" watch.
    public mutating func tick(at t: Double) {
        guard !formatChanged, let since = lastValidA ?? armedAt else { return }
        if t - since > T.t07NoPacketAS {
            formatChanged = true
            formatChangeReason = "No valid packet A for \(Int(T.t07NoPacketAS)) s"
        }
    }

    private mutating func record(t: Double, failed: Bool) {
        window.append((t, failed))
        while let first = window.first, t - first.t > T.t07WindowS { window.removeFirst() }
        tick(at: t)
        // Needs a reasonable sample (a third of a minute of packets) before judging the share.
        guard !formatChanged, window.count >= 40, let first = window.first, t - first.t >= 10 else { return }
        let share = Double(window.filter { $0.failed }.count) / Double(window.count)
        if share > T.t07FailedFrameShare {
            formatChanged = true
            failedShareTripped = true
            formatChangeReason = "\(Int((share * 100).rounded()))% of frames failed the checks in the last minute"
        }
    }
}
