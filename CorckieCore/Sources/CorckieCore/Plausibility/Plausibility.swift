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
    /// Note 10: the readings dropped, per kind (speed / battery / voltage / temperature / odometer)
    public private(set) var ignoredByField: [String: Int] = [:]
    /// Note 10: the newest dropped values (what the ride summary's plain-words note quotes)
    public private(set) var lastDroppedSpeedKmh: Double?
    public private(set) var lastDroppedBatteryPct: Int?
    public private(set) var lastDroppedTempC: Double?
    /// Note 12: the format watch tripped at least once since the last connection (`formatChanged` clears when trust returns)
    public private(set) var formatChangeSeen = false
    /// Note 12: how often trust came back after a trip (connection diagnostics)
    public private(set) var trustRecovered = 0

    /// Note 12 (owner 24 Oct, the lift): right after scooter-on the readings can be garbled for a few seconds. The format
    /// watch does not judge until they settle: `warmUpGoodFrames` valid packet-A frames in a row, or `warmUpMaxS` after
    /// the connection, whichever comes first. A real format change (P-6) keeps failing after that and still trips.
    public static let warmUpGoodFrames = 5
    public static let warmUpMaxS = 30.0
    /// Note 12: trust returns after this many valid packet-A frames in a row
    public static let recoverGoodFrames = 10
    private var connectedAt: Double?
    private var settled = false
    private var goodRun = 0
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
        // Note 12: a new connection is judged afresh (before, one false alarm kept every later ride of the session on the phone)
        formatChanged = false
        failedShareTripped = false
        formatChangeReason = nil
        formatChangeSeen = false
        connectedAt = t
        settled = false
        goodRun = 0
    }

    private mutating func recover() {
        formatChanged = false
        failedShareTripped = false
        formatChangeReason = nil
        window.removeAll()
        trustRecovered += 1
    }

    /// Note 12: still in the warm-up after scooter-on (the watch does not judge yet)
    public func warmingUp(at t: Double) -> Bool {
        guard !settled else { return false }
        guard let from = connectedAt ?? armedAt else { return true }
        return t - from < Self.warmUpMaxS
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
            // Note 12: readings that look normal end the warm-up, and bring trust back after a trip
            goodRun = dropped.isEmpty ? goodRun + 1 : 0
            if !settled, goodRun >= Self.warmUpGoodFrames { settled = true }
            if formatChanged, !failedShareTripped, goodRun >= Self.recoverGoodFrames { recover() }   // "no packet A": packets are back
        }
        // Temperature outside T06 (nil = "no reading", never dropped)
        if let c = f.temperatureC, c < T.t06MinTempC || c > T.t06MaxTempC {
            f.temperatureC = nil
            dropped.append(.temperature)
        }

        ignoredReadings += dropped.count
        for d in dropped { ignoredByField[d.rawValue, default: 0] += 1 }
        if dropped.contains(.speed) { lastDroppedSpeedKmh = input.speedKmh }
        if dropped.contains(.battery) { lastDroppedBatteryPct = input.batteryPct }
        if dropped.contains(.temperature) { lastDroppedTempC = input.temperatureC }
        record(t: t, failed: !dropped.isEmpty)
        return Result(frame: f, dropped: dropped)
    }

    /// Call regularly (every packet, or a 1 s tick) to run the "no packet A for 10 s" watch.
    public mutating func tick(at t: Double) {
        guard !formatChanged, !warmingUp(at: t), let since = lastValidA ?? armedAt else { return }
        if t - since > T.t07NoPacketAS {
            formatChanged = true
            formatChangeSeen = true
            formatChangeReason = "No valid packet A for \(Int(T.t07NoPacketAS)) s"
        }
    }

    private mutating func record(t: Double, failed: Bool) {
        // Note 12: frames of the warm-up are checked (bad values dropped) but not judged
        if warmingUp(at: t) {
            tick(at: t)
            return
        }
        window.append((t, failed))
        while let first = window.first, t - first.t > T.t07WindowS { window.removeFirst() }
        tick(at: t)
        // Needs a reasonable sample (a third of a minute of packets) before judging the share.
        // The share rule keeps watching after a "no packet A" trip, so the ride engine can still act on it
        guard window.count >= 40, let first = window.first, t - first.t >= 10 else { return }
        let share = Double(window.filter { $0.failed }.count) / Double(window.count)
        if failedShareTripped {
            // Note 12: trust returns once the readings look normal again (a quiet minute and a run of good frames)
            if share < T.t07FailedFrameShare / 2, goodRun >= Self.recoverGoodFrames { recover() }
            return
        }
        if share > T.t07FailedFrameShare {
            formatChanged = true
            failedShareTripped = true
            formatChangeSeen = true
            formatChangeReason = "\(Int((share * 100).rounded()))% of frames failed the checks in the last minute"
        }
    }
}
