import Foundation

// N10-1 … N10-11 (batch 10): one number per ride (or charge / park) for each fault, measured from the scooter's own readings.
// The numbers go through FaultGate; nothing here decides to tell the rider. Lines come from the audit of the owner's 53 rides
// (reports, 20 Nov 2026). Frames are ScooterFrame (t in seconds); no clock time is read or kept.

public enum FaultDetectors {

    // MARK: N10-1 · F1 battery strain (sag per amp)

    /// The first minutes are skipped: a cold battery sags more (audit: higher in the first ~6 min)
    public static let f1SkipS = 6.0 * 60
    /// Windows of 3 minutes; a window needs this spread of current to read a slope
    public static let f1WindowS = 3.0 * 60
    public static let f1MinSpreadA = 5.0
    public static let f1MinPoints = 20

    /// Per-ride battery strain in milliohms (voltage drop per amp): the median over 3-minute windows after the first 6 min.
    /// nil when the ride is too short or never pulls enough current.
    public static func f1SagMilliohm(_ frames: [ScooterFrame]) -> Double? {
        guard let t0 = frames.first?.t else { return nil }
        let pts: [(t: Double, v: Double, i: Double)] = frames.compactMap { f in
            guard f.t - t0 >= f1SkipS, let v = f.voltage, let i = f.currentA, (f.ageA ?? 0) < 2, (f.ageB ?? 0) < 2 else { return nil }
            return (f.t, v, i)
        }
        guard let first = pts.first?.t else { return nil }
        var buckets: [Int: [(v: Double, i: Double)]] = [:]
        for p in pts { buckets[Int((p.t - first) / f1WindowS), default: []].append((p.v, p.i)) }
        var slopes: [Double] = []
        for (_, w) in buckets where w.count >= f1MinPoints {
            let currents = w.map(\.i)
            guard let lo = currents.min(), let hi = currents.max(), hi - lo >= f1MinSpreadA else { continue }
            let n = Double(w.count)
            let mi = currents.reduce(0, +) / n
            let mv = w.map(\.v).reduce(0, +) / n
            var sxy = 0.0, sxx = 0.0
            for p in w { sxy += (p.i - mi) * (p.v - mv); sxx += (p.i - mi) * (p.i - mi) }
            guard sxx > 0 else { continue }
            let slope = -sxy / sxx * 1000   // volts lost per amp → milliohms
            if slope > 0 { slopes.append(slope) }
        }
        return median(slopes)
    }

    /// F1 normals are kept per air-temperature band of 5 °C (colder air = more sag); no air temperature → one shared band
    public static func f1Band(airC: Double?) -> String {
        guard let a = airC else { return "air?" }
        return "air\(Int((a / 5).rounded(.down)) * 5)"
    }

    // MARK: N10-2 · F2 power cuts at speed

    /// The scooter's own shut-off signal while the wheel was above this speed
    public static let f2MinKmh = 10.0

    /// Times (s) the scooter's shut-off signal came on while moving faster than 10 km/h. The "link lost + fresh start" path is added
    /// after the standing test on the new scooter (owner 20 Nov).
    public static func f2PowerCutTimes(_ frames: [ScooterFrame]) -> [Double] {
        var out: [Double] = []
        var prev: ScooterFrame?
        for f in frames {
            if f.shuttingDown, prev?.shuttingDown == false, let s = prev?.speedKmh, s > f2MinKmh { out.append(f.t) }
            prev = f
        }
        return out
    }

    // MARK: N10-3 · F3 motor not cut while braking

    public static let f3MinS = 3.0
    /// Current that counts as "motor still pulling" (the audit's single-reading overlaps reached 21 A, so the time rule does the work)
    public static let f3MinA = 2.0
    /// A gap longer than this between readings breaks a run
    public static let f3MaxGapS = 1.5

    /// End times (s) of runs where the brake signal was on while the motor drew current for 3+ seconds (audit: longest healthy 0.6 s)
    public static func f3BrakeRuns(_ frames: [ScooterFrame]) -> [Double] {
        var out: [Double] = []
        var start: Double?
        var last: Double?
        func close() {
            if let s = start, let l = last, l - s >= f3MinS { out.append(l) }
            start = nil
        }
        for f in frames {
            let on = f.brake && (f.currentA ?? 0) > f3MinA
            if let l = last, f.t - l > f3MaxGapS { close() }
            if on {
                if start == nil { start = f.t }
                last = f.t
            } else {
                close()
                last = f.t
            }
        }
        close()
        return out
    }

    // MARK: N10-5 · F5 tyre (same-route wheel vs GPS)

    /// Rides on the route in each median
    public static let f5Rides = 10

    /// Shift (%) of the median wheel/GPS ratio of the last 10 rides on a route from the median of the first 10 (oldest first).
    /// nil until the route has 20 rides with a ratio. Single bad rides (GPS trouble: 1.05, 1.14, 1.37) can't move a median.
    public static func f5ShiftPct(routeRatios ratios: [Double]) -> Double? {
        guard ratios.count >= 2 * f5Rides, let ref = median(Array(ratios.prefix(f5Rides))),
              let now = median(Array(ratios.suffix(f5Rides))), ref > 0 else { return nil }
        return abs(now - ref) / ref * 100
    }

    // MARK: N10-6 · F6 heat the load doesn't explain

    /// One normal ride for the heat model: motor rise over the air, effort (Wh per minute) and ride minutes
    public struct HeatPoint: Codable, Equatable, Sendable {
        public var riseC: Double
        public var whPerMin: Double
        public var minutes: Double
        public init(riseC: Double, whPerMin: Double, minutes: Double) {
            self.riseC = riseC
            self.whPerMin = whPerMin
            self.minutes = minutes
        }
    }

    /// The learned model (rise ≈ a + b·effort + c·minutes), fitted on the rider's normal rides. nil under 10 rides or when the
    /// rides don't vary enough to fit.
    public static func f6Model(_ pts: [HeatPoint]) -> (a: Double, b: Double, c: Double)? {
        guard pts.count >= FaultGate.learnRides else { return nil }
        // normal equations for 3 unknowns
        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
        for p in pts {
            let x = [1, p.whPerMin, p.minutes]
            for r in 0..<3 {
                for c in 0..<3 { m[r][c] += x[r] * x[c] }
                m[r][3] += x[r] * p.riseC
            }
        }
        // Gauss–Jordan with partial pivoting
        for col in 0..<3 {
            guard let piv = (col..<3).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[piv][col]) > 1e-9 else { return nil }
            m.swapAt(col, piv)
            let d = m[col][col]
            for c in col..<4 { m[col][c] /= d }
            for r in 0..<3 where r != col {
                let k = m[r][col]
                for c in col..<4 { m[r][c] -= k * m[col][c] }
            }
        }
        return (m[0][3], m[1][3], m[2][3])
    }

    /// °C over the model on this ride (positive = hotter than the load explains)
    public static func f6OverModelC(_ p: HeatPoint, model: (a: Double, b: Double, c: Double)) -> Double {
        p.riseC - (model.a + model.b * p.whPerMin + model.c * p.minutes)
    }

    /// The fixed line from the audit: 10 °C over the model (usual miss ±4.6, worst normal +9.2)
    public static let f6LineC = 10.0

    // MARK: N10-7 · F7 impossible sensor readings

    /// Single-reading temperature jumps of more than this, and back
    public static let f7DipC = 10.0
    /// The line: 5+ dips per ride (healthy max 2), or any other impossible reading
    public static let f7Line = 4.5

    /// The ride's impossible-reading score: the count of single-reading temperature dips, or 5 when the temperature says "no
    /// reading" mid-ride without a link drop, or the wheel reads 0 while drawing current at GPS speed above 10 km/h.
    /// `gpsKmhAt` gives the phone's speed at a time (nil when unknown); `linkDropTimes` are reconnects in this ride.
    public static func f7Score(_ frames: [ScooterFrame], gpsKmhAt: (Double) -> Double? = { _ in nil }, linkDropTimes: [Double] = []) -> Double {
        let temps = frames.compactMap { f -> (t: Double, c: Double)? in f.temperatureC.map { (f.t, $0) } }
        var dips = 0
        if temps.count >= 3 {
            for k in 1..<(temps.count - 1) {
                let a = temps[k - 1].c, b = temps[k].c, c = temps[k + 1].c
                if abs(b - a) > f7DipC && abs(b - c) > f7DipC && abs(a - c) <= f7DipC / 2 { dips += 1 }
            }
        }
        var impossible = false
        var seenTemp = false
        for f in frames {
            if f.temperatureC != nil { seenTemp = true }
            if seenTemp && f.temperatureNoReading {
                let nearDrop = linkDropTimes.contains { abs($0 - f.t) < 30 }
                if !nearDrop { impossible = true }
            }
            if let w = f.speedKmh, w == 0, (f.currentA ?? 0) > f3MinA, let g = gpsKmhAt(f.t), g > 10 { impossible = true }
        }
        return max(Double(dips), impossible ? 5 : 0)
    }

    // MARK: N10-9 · F11 parked drain

    /// Parks shorter than this are skipped
    public static let f11MinHours = 12.0
    /// A park that starts this close to the rider's full voltage is skipped (post-charge settling looks like drain)
    public static let f11NearFullV = 0.5

    /// Volts lost per day while parked, or nil when the park doesn't count: shorter than 12 h, the odometer moved (someone rode
    /// it), the voltage rose (a charge happened), or it started within 0.5 V of the rider's full voltage.
    public static func f11DrainVPerDay(startV: Double, endV: Double, hours: Double, odoStartKm: Double?, odoEndKm: Double?,
                                       fullV: Double?) -> Double? {
        guard hours >= f11MinHours else { return nil }
        if let a = odoStartKm, let b = odoEndKm, abs(b - a) >= 0.1 { return nil }
        guard endV <= startV else { return nil }
        if let full = fullV, startV >= full - f11NearFullV { return nil }
        return (startV - endV) / hours * 24
    }

    // MARK: N10-10 · F12 voltage at full

    /// The first seconds after switch-on show a fake 100 % (audit): skipped
    public static let f12SkipS = 10.0

    /// The first resting voltage after a charge: standing still, almost no current, after the first 10 seconds
    public static func f12RestingVoltage(_ frames: [ScooterFrame]) -> Double? {
        guard let t0 = frames.first?.t else { return nil }
        return frames.first { f in
            f.t - t0 >= f12SkipS && (f.speedKmh ?? 1) == 0 && abs(f.currentA ?? 99) < 1 && f.voltage != nil
        }?.voltage
    }

    /// The step under the rider's lowest normal full voltage (the gate adds 10 %)
    public static let f12StepV = 0.5

    // MARK: N10-11 · F16 km counter reset

    /// The odometer went backwards or to near 0. Judged across parks too (riding can't lower it); a forward jump across a park is
    /// someone else riding and is ignored.
    public static func f16Reset(previousKm: Double?, nowKm: Double?) -> Bool {
        guard let p = previousKm, let n = nowKm else { return false }
        return n < p - 0.5 || (n < 1 && p >= 5)
    }

    /// A big forward jump while connected, held for 10+ readings (one wrong reading is not a reset)
    public static func f16JumpInRide(_ frames: [ScooterFrame], jumpKm: Double = 5, hold: Int = 10) -> Bool {
        let odo = frames.compactMap(\.odometerKm)
        guard odo.count > hold else { return false }
        for k in 1..<odo.count where abs(odo[k] - odo[k - 1]) >= jumpKm {
            let after = odo[k..<min(odo.count, k + hold)]
            // the new number holds, and it is not just the return to what the counter showed before a single wrong reading
            let before = odo[max(0, k - hold)..<k]
            let sameAsBefore = before.filter { abs($0 - odo[k]) < jumpKm / 2 }.count * 2 >= before.count
            if after.count >= hold && after.allSatisfy({ abs($0 - odo[k]) < jumpKm / 2 }) && !sameAsBefore { return true }
        }
        return false
    }

    // MARK: helpers

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
