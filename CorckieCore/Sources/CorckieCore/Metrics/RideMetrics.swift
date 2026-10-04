import Foundation

/// One stored moment of a ride (the `ride_sample` row, seconds instead of ms) · DATA_MODEL §2.
/// Everything the ride metrics need is in these rows, so a ride can be re-computed from storage
/// alone (CALC_SPEC "Re-run"). Times are seconds from the ride start.
public struct RideSample: Equatable, Sendable {
    public var t: Double
    /// Scooter wheel speed, km/h (nil in a scooter gap)
    public var speedKmh: Double?
    /// Phone GPS speed, km/h
    public var gpsSpeedKmh: Double?
    public var lat: Double?
    public var lon: Double?
    /// Horizontal accuracy, m (nil = no fix)
    public var hAccM: Double?
    /// Barometer relative altitude, m
    public var altBaroM: Double?
    public var voltage: Double?
    public var currentA: Double?
    public var batteryPct: Int?
    public var tempC: Double?
    public var odometerKm: Double?
    /// From the ride engine (M3 stops); nil = derive it from the speed
    public var moving: Bool?

    public init(t: Double, speedKmh: Double? = nil, gpsSpeedKmh: Double? = nil, lat: Double? = nil, lon: Double? = nil,
                hAccM: Double? = nil, altBaroM: Double? = nil, voltage: Double? = nil, currentA: Double? = nil,
                batteryPct: Int? = nil, tempC: Double? = nil, odometerKm: Double? = nil, moving: Bool? = nil) {
        self.t = t
        self.speedKmh = speedKmh
        self.gpsSpeedKmh = gpsSpeedKmh
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.altBaroM = altBaroM
        self.voltage = voltage
        self.currentA = currentA
        self.batteryPct = batteryPct
        self.tempC = tempC
        self.odometerKm = odometerKm
        self.moving = moving
    }

    /// W (voltage × current)
    public var powerW: Double? {
        guard let v = voltage, let i = currentA else { return nil }
        return v * i
    }

    /// A fix good enough to trust (T28)
    public var hasGoodFix: Bool {
        guard let h = hAccM, lat != nil, lon != nil else { return false }
        return h >= 0 && h <= T.t28GoodFixM
    }
}

/// Turns the live frame (+ the newest phone fix and barometer reading) into one `RideSample`
/// every `intervalS` seconds. Shared by the Recorder (M1-09) and the tests, so what is tested
/// is what is stored.
public struct RideSampler: Sendable {
    public let intervalS: Double
    /// A phone fix older than this is not attached to a sample
    public static let maxFixAgeS = 5.0
    private var nextT: Double?
    private var fix: PhoneFix?
    private var baro: BaroReading?
    var nextDueT: Double? {
        get { nextT }
        set { nextT = newValue }
    }
    var lastBaro: BaroReading? { baro }

    public init(intervalS: Double = 5) {
        self.intervalS = intervalS
    }

    public mutating func update(fix: PhoneFix) { self.fix = fix }
    public mutating func update(baro: BaroReading) { self.baro = baro }

    /// Offer the frame after every packet; returns a sample when one is due.
    /// `startT` = the ride's start on the same clock (sample `t` = frame time − startT).
    public mutating func offer(_ frame: ScooterFrame, startT: Double) -> RideSample? {
        if let due = nextT, frame.t < due { return nil }
        nextT = frame.t + intervalS
        var s = RideSample(t: frame.t - startT)
        s.speedKmh = frame.speedKmh
        s.voltage = frame.voltage
        s.currentA = frame.currentA
        s.batteryPct = frame.batteryPct
        s.tempC = frame.temperatureC
        s.odometerKm = frame.odometerKm
        if let f = fix, frame.t - f.t <= Self.maxFixAgeS, frame.t >= f.t {
            s.lat = f.lat
            s.lon = f.lon
            s.hAccM = f.hAccM >= 0 ? f.hAccM : nil
            s.gpsSpeedKmh = f.speedMps >= 0 ? f.speedMps * 3.6 : nil
        }
        if let b = baro, frame.t - b.t <= Self.maxFixAgeS, frame.t >= b.t {
            s.altBaroM = b.relativeAltitudeM
        }
        return s
    }
}

extension RideSampler {
    /// M1-05 phone mode: a GPS-only sample (no scooter fields, so no energy and no wheel distance; the path keeps
    /// going for the dashed stretch on the map). Shares the 5-s rhythm with `offer(_:startT:)`.
    public mutating func offer(fix f: PhoneFix, startT: Double) -> RideSample? {
        update(fix: f)
        guard f.isGood else { return nil }
        if let due = nextDueT, f.t < due { return nil }
        nextDueT = f.t + intervalS
        var s = RideSample(t: f.t - startT)
        s.lat = f.lat
        s.lon = f.lon
        s.hAccM = f.hAccM >= 0 ? f.hAccM : nil
        s.gpsSpeedKmh = f.speedMps >= 0 ? f.speedMps * 3.6 : nil
        if let b = lastBaro, f.t - b.t <= Self.maxFixAgeS, f.t >= b.t { s.altBaroM = b.relativeAltitudeM }
        return s
    }
}

/// M3 stop as the metrics need it (seconds from the ride start).
public struct RideStopSpan: Equatable, Sendable {
    public var startT: Double
    public var endT: Double?
    public init(startT: Double, endT: Double?) {
        self.startT = startT
        self.endT = endT
    }
}

/// The ride's numbers · CALC_SPEC M4–M10, M38. Optional = "not known" (never a made-up zero).
public struct RideMetrics: Equatable, Sendable {
    /// M4: last move − first move, s
    public var totalS = 0.0
    /// Time moving (stops excluded), s
    public var movingS = 0.0
    public var firstMoveT: Double?
    public var lastMoveT: Double?
    /// M5: odometer × wheel factor, minus lifted-wheel stretches (T32), m
    public var distanceM = 0.0
    /// Where the distance came from: odometer / wheel / gps / none
    public var distanceSource = "none"
    /// Wheel distance excluded because the wheel turned while the phone did not move (T32), m
    public var liftedWheelM = 0.0
    public var odoStartKm: Double?
    public var odoEndKm: Double?
    /// M6: distance ÷ moving time, m/s
    public var avgMovingMps: Double?
    /// M7: top speed held ≥ T33, GPS-confirmed, × wheel factor, km/h
    public var topSpeedKmh = 0.0
    /// M3: number of stops
    public var stops = 0
    /// D3 / T102: distance walked (pushing) inside the ride, m; counted in `distanceM`, left out of M6 and M9
    public var walkedM = 0.0
    /// M8: Σ V × I × Δt, Wh
    public var energyWhRaw = 0.0
    public var startRestPct: Double?
    public var endRestPct: Double?
    /// M8 before calibration: start rested % − end rested %
    public var usedPct: Double?
    public var usedPctMethod: String?
    /// M9: used % per km, shown "~" before calibration, nil before T43 (1 km)
    public var pctPerKm: Double?
    public var pctPerKmApproximate = true
    /// M10 (barometer only, provisional "~"): nil when there was no barometer
    public var elevGainM: Double?
    public var elevLossM: Double?
    public var elevProvisional = true
    /// M38
    public var tempStartC: Double?
    public var tempPeakC: Double?
    public var tempRiseC: Double?
    /// Scooter data missing between samples (disconnect), s
    public var gapScooterS = 0.0
    public var hasGps = false
    /// From the plausibility filter, shown in ⋯ info as "Some scooter readings were ignored"
    public var ignoredReadings = 0

    public var distanceKm: Double { distanceM / 1000 }
    public var topSpeedMps: Double { topSpeedKmh / 3.6 }
    public var showsIgnoredReadingsNote: Bool { ignoredReadings > 0 }
    public var usedPctM9Shown: Bool { pctPerKm != nil }

    /// The "~N%/km" text for the live view and the summary; "—" before 1 km (M9).
    public var pctPerKmText: String {
        guard let v = pctPerKm else { return "—" }
        return (pctPerKmApproximate ? "~" : "") + String(format: "%.1f", v) + " %/km"
    }
}

public enum RideMetricsCalculator {
    /// A gap between samples longer than this is a scooter gap (samples are 5 s apart, so 6 s ± one lost sample).
    public static let defaultMaxStepS = 6.0

    /// Computes the ride numbers from its stored samples.
    /// - Parameters:
    ///   - stops: M3 stop rows when the engine has them; otherwise stops are counted from the samples.
    ///   - walks: D3 walking stretches from the engine (their distance counts, but not in avg. speed or %/km).
    ///   - wheelFactor: M5 wheel factor, 1.0 until 5 clean stretches exist (T31).
    ///   - maxStepS: samples further apart than this are a gap (no energy, no wheel distance between them).
    public static func compute(_ input: [RideSample], stops: [RideStopSpan]? = nil, walks: [RideStopSpan] = [],
                               ignoredReadings: Int = 0,
                               wheelFactor: Double = 1.0, maxStepS: Double = defaultMaxStepS) -> RideMetrics {
        var m = RideMetrics()
        m.ignoredReadings = ignoredReadings
        let samples = input.sorted { $0.t < $1.t }
        guard !samples.isEmpty else { return m }
        m.hasGps = samples.contains { $0.hasGoodFix }

        let moving = movingFlags(samples)

        // M4 time, moving time
        if let first = moving.firstIndex(of: true), let last = moving.lastIndex(of: true) {
            m.firstMoveT = samples[first].t
            m.lastMoveT = samples[last].t
            m.totalS = samples[last].t - samples[first].t
            for i in first..<last {
                let dt = samples[i + 1].t - samples[i].t
                if moving[i], dt > 0, dt <= maxStepS { m.movingS += dt }
            }
        }

        // M3 stops (count only; the rows come from the engine)
        if let stops {
            m.stops = stops.count
        } else {
            m.stops = countStops(samples, moving)
        }

        // gaps, M8 raw energy
        for i in 1..<max(samples.count, 1) {
            let a = samples[i - 1], b = samples[i]
            let dt = b.t - a.t
            guard dt > 0 else { continue }
            let scooterCovered = a.speedKmh != nil && b.speedKmh != nil && dt <= maxStepS
            if !scooterCovered { m.gapScooterS += dt }
            if dt <= maxStepS, let pa = a.powerW, let pb = b.powerW {
                m.energyWhRaw += (pa + pb) / 2 * dt / 3600
            }
        }

        // M5 distance
        applyDistance(to: &m, samples, wheelFactor: wheelFactor, maxStepS: maxStepS)

        // D3: walked distance (left sample inside a walking stretch)
        if !walks.isEmpty {
            for i in 1..<samples.count {
                let a = samples[i - 1], b = samples[i]
                let dt = b.t - a.t
                guard dt > 0, dt <= maxStepS,
                      walks.contains(where: { a.t >= $0.startT && a.t < ($0.endT ?? .infinity) }) else { continue }
                m.walkedM += (a.speedKmh ?? a.gpsSpeedKmh ?? 0) / 3.6 * dt * wheelFactor
            }
            m.walkedM = min(m.walkedM, m.distanceM)
        }
        let riddenM = m.distanceM - m.walkedM

        // M6 (walking left out)
        if m.movingS > 0, riddenM > 0 { m.avgMovingMps = riddenM / m.movingS }

        // M7
        m.topSpeedKmh = topSpeed(samples, wheelFactor: wheelFactor, maxStepS: maxStepS)

        // M8 rested %
        m.startRestPct = restedStart(samples, moving)
        m.endRestPct = restedEnd(samples, moving)
        if let a = m.startRestPct, let b = m.endRestPct {
            m.usedPct = max(0, a - b)
            m.usedPctMethod = "rested"
        }

        // M9
        if let used = m.usedPct, riddenM >= T.t43BatteryPerKmAfterM {
            m.pctPerKm = used / (riddenM / 1000)
        }

        // M10
        let (gain, loss) = elevation(samples)
        m.elevGainM = gain
        m.elevLossM = loss

        // M38
        let temps = samples.compactMap(\.tempC)
        m.tempStartC = temps.first
        m.tempPeakC = temps.max()
        if let a = m.tempStartC, let p = m.tempPeakC { m.tempRiseC = p - a }
        return m
    }

    // MARK: Moving / stops (M3 fallback when the engine gives no flag)

    /// The engine's flag when there is one; otherwise speed with the stop hysteresis:
    /// a stop starts below T23 (3 km/h) and ends above T24 (5 km/h).
    static func movingFlags(_ samples: [RideSample]) -> [Bool] {
        var out: [Bool] = []
        var state = false
        for s in samples {
            if let flag = s.moving {
                out.append(flag)
                state = flag
                continue
            }
            let v = s.speedKmh ?? s.gpsSpeedKmh
            if let v {
                if state { state = v >= T.t23StopKmh } else { state = v > T.t24StopEndKmh }
            }
            out.append(state)
        }
        return out
    }

    /// A stop = a not-moving stretch of at least T23 (3 s) between two moving samples.
    static func countStops(_ samples: [RideSample], _ moving: [Bool]) -> Int {
        guard let first = moving.firstIndex(of: true), let last = moving.lastIndex(of: true), first < last else { return 0 }
        var count = 0
        var stopStart: Double?
        for i in first...last {
            if !moving[i] {
                if stopStart == nil { stopStart = samples[i].t }
            } else if let s = stopStart {
                if samples[i].t - s >= T.t23StopS { count += 1 }
                stopStart = nil
            }
        }
        return count
    }

    // MARK: M5 distance

    static func applyDistance(to m: inout RideMetrics, _ samples: [RideSample], wheelFactor: Double, maxStepS: Double) {
        let odo = samples.compactMap(\.odometerKm)
        m.odoStartKm = odo.first
        m.odoEndKm = odo.last

        // Lifted / spinning wheel (T32): wheel distance ≥ 50 m while the phone moved < 5 m (good fixes only)
        var lifted = 0.0
        var anchor: RideSample?
        var wheelSince = 0.0
        var wheelTotal = 0.0
        var gpsTotal = 0.0
        var lastGood: RideSample?
        for i in samples.indices {
            let s = samples[i]
            var step = 0.0
            if i > 0 {
                let a = samples[i - 1]
                let dt = s.t - a.t
                if dt > 0, dt <= maxStepS, let v = a.speedKmh { step = v / 3.6 * dt * wheelFactor }
            }
            wheelTotal += step
            if s.hasGoodFix {
                if let g = lastGood, s.t - g.t <= maxStepS { gpsTotal += meters(g, s) }
                lastGood = s
                if anchor == nil { anchor = s; wheelSince = 0 } else { wheelSince += step }
                if let a = anchor, wheelSince >= T.t32LiftedWheelM {
                    if meters(a, s) < T.t32LiftedGpsM { lifted += wheelSince }
                    anchor = s
                    wheelSince = 0
                }
            } else {
                anchor = nil
                lastGood = nil
                wheelSince = 0
            }
        }
        m.liftedWheelM = lifted

        if let a = odo.first, let b = odo.last {
            m.distanceM = max(0, (b - a) * 1000 * wheelFactor - lifted)
            m.distanceSource = "odometer"
        } else if wheelTotal > 0 {
            m.distanceM = max(0, wheelTotal - lifted)
            m.distanceSource = "wheel"
        } else if gpsTotal > 0 {
            m.distanceM = gpsTotal
            m.distanceSource = "gps"
        }
    }

    /// Cumulative distance per sample, m: wheel speed × time between odometer steps, re-anchored to the
    /// odometer at each 0.1 km step, so the live value is smooth and the total exact (CALC_SPEC M5).
    public static func distanceSeries(_ input: [RideSample], wheelFactor: Double = 1.0, maxStepS: Double = defaultMaxStepS) -> [Double] {
        let samples = input.sorted { $0.t < $1.t }
        guard let odoStart = samples.compactMap(\.odometerKm).first else { return samples.map { _ in 0 } }
        var out: [Double] = []
        var lastOdo = odoStart
        var anchorM = 0.0
        var wheelSince = 0.0
        var prev = 0.0
        for i in samples.indices {
            if i > 0 {
                let a = samples[i - 1]
                let dt = samples[i].t - a.t
                if dt > 0, dt <= maxStepS, let v = a.speedKmh { wheelSince += v / 3.6 * dt * wheelFactor }
            }
            if let o = samples[i].odometerKm, o != lastOdo {
                lastOdo = o
                anchorM = (o - odoStart) * 1000 * wheelFactor
                wheelSince = 0
            }
            // between two 0.1 km steps the wheel estimate may not run past the next step
            let value = max(prev, anchorM + min(wheelSince, 100 * wheelFactor))
            out.append(value)
            prev = value
        }
        return out
    }

    static func meters(_ a: RideSample, _ b: RideSample) -> Double {
        guard let la1 = a.lat, let lo1 = a.lon, let la2 = b.lat, let lo2 = b.lon else { return 0 }
        let r = 6_371_000.0
        let p1 = la1 * .pi / 180, p2 = la2 * .pi / 180
        let dp = (la2 - la1) * .pi / 180, dl = (lo2 - lo1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    // MARK: M7 top speed

    /// The highest speed held for at least T33 (1 s): the minimum of a window spanning ≥ 1 s, maximised over
    /// all windows. A sample counts only when the phone confirms movement (GPS speed > 5 km/h with a good
    /// fix) or has no good fix at all; there is no fixed maximum (P4 D1 A2).
    static func topSpeed(_ samples: [RideSample], wheelFactor: Double, maxStepS: Double) -> Double {
        var window: [(t: Double, kmh: Double)] = []
        var best = 0.0
        var prevT: Double?
        for s in samples {
            defer { prevT = s.t }
            guard let v = s.speedKmh else { window.removeAll(); continue }
            if let p = prevT, s.t - p > maxStepS { window.removeAll() }
            if s.hasGoodFix, let g = s.gpsSpeedKmh, g <= 5 {
                window.removeAll()
                continue
            }
            window.append((s.t, v * wheelFactor))
            while window.count > 1, s.t - window[1].t >= T.t33TopSpeedHeldS { window.removeFirst() }
            if let first = window.first, s.t - first.t >= T.t33TopSpeedHeldS {
                best = max(best, window.map { $0.kmh }.min() ?? 0)
            }
        }
        return best
    }

    // MARK: M8 rested %

    /// Start: median battery % of the first T40 (5 s) of the ride while standing; else the first reading.
    static func restedStart(_ samples: [RideSample], _ moving: [Bool]) -> Double? {
        guard let t0 = samples.first?.t else { return nil }
        let early = samples.indices.filter { samples[$0].t - t0 <= T.t40StartWindowS && !moving[$0] }
            .compactMap { samples[$0].batteryPct }
        if let med = median(early.map(Double.init)) { return med }
        return samples.compactMap(\.batteryPct).first.map(Double.init)
    }

    /// End: median battery % after ≥ T40 (20 s) at standstill with current < 0.2 A at the ride's end; else nil.
    static func restedEnd(_ samples: [RideSample], _ moving: [Bool]) -> Double? {
        guard let lastT = samples.last?.t else { return nil }
        var restedFrom: Double?
        var pcts: [Double] = []
        for i in samples.indices.reversed() {
            let s = samples[i]
            guard !moving[i], let c = s.currentA, abs(c) < T.t40RestedCurrentA else { break }
            restedFrom = s.t
            if let p = s.batteryPct { pcts.append(Double(p)) }
        }
        guard let from = restedFrom, lastT - from >= T.t40RestedS else { return nil }
        return median(pcts)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: M10 elevation (barometer only)

    /// A change faster than 3 m/s is a spike and is dropped (T50); gain / loss count once the altitude is 2 m
    /// away from the last counted level (hysteresis). The 2-s median is the Recorder's job on the raw readings.
    static func elevation(_ samples: [RideSample]) -> (gain: Double?, loss: Double?) {
        var gain = 0.0, loss = 0.0
        var anchor: Double?
        var lastAccepted: (t: Double, alt: Double)?
        var seen = false
        for s in samples {
            guard let alt = s.altBaroM else { continue }
            seen = true
            if let l = lastAccepted, s.t > l.t, abs(alt - l.alt) / (s.t - l.t) > T.t50BaroSpikeMps { continue }
            lastAccepted = (s.t, alt)
            guard let a = anchor else { anchor = alt; continue }
            if alt - a >= T.t50BaroHysteresisM {
                gain += alt - a
                anchor = alt
            } else if a - alt >= T.t50BaroHysteresisM {
                loss += a - alt
                anchor = alt
            }
        }
        return seen ? (gain, loss) : (nil, nil)
    }
}

/// M38 live heat watch: *hot* ≥ 90 °C and *very hot* ≥ 100 °C (T47), each announced once per ride;
/// *very hot* stays until the temperature is below *hot*.
public struct HeatWatch: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case normal = 0, hot, veryHot
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public private(set) var level: Level = .normal
    public private(set) var announced: Level = .normal
    public let hotC: Double
    public let veryHotC: Double

    public init(hotC: Double = T.t47HotC, veryHotC: Double = T.t47VeryHotC) {
        self.hotC = hotC
        self.veryHotC = veryHotC
    }

    /// Feed a temperature; returns the level to announce now (first time this ride), if any.
    @discardableResult
    public mutating func update(_ tempC: Double) -> Level? {
        if tempC >= veryHotC {
            level = .veryHot
        } else if level == .veryHot, tempC >= hotC {
            level = .veryHot
        } else if tempC >= hotC {
            level = .hot
        } else {
            level = .normal
        }
        if level > announced {
            announced = level
            return level
        }
        return nil
    }
}
