import Foundation

/// Insights plan (owner, Mon 26 Oct, FEASIBILITY_2026-10-26 "DECIDED" + "Follow-ups decided"), batch 102:
/// 1. learn from WHOLE-RIDE battery %/km (noise ~7 %), not from second-by-second power (~29 %): every insight below is a fit of one
///    ride-level number against %/km; the sweet spot's steady-stretch maths is retired (graphs keep their full detail; the live F-22
///    warnings are separate code and untouched);
/// 2. the sweet spot becomes "What speed costs you" (ride level);
/// 3. no "Can't learn this": gentle words, the PARTIAL result (solid where there is data, a dashed top / bottom band where it is thin)
///    and one short hint ("Ride steady at 25–35 km/h to fill this in.");
/// 4. order: Hills → Speed cost → Battery over time → Temperature → Wind → Best time to leave;
/// progress from the real maths: "About 7 more rides" (rides for the effect seen so far to be real: p < 0.05, 80 % power), rounded.
/// Pure, so it is tested on Linux.

public struct RideLevelRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var distanceKm: Double
    public var pctPerKm: Double
    public var avgKmh: Double?
    public var climbMPerKm: Double?
    public var airTempC: Double?
    public var headwindKmh: Double?

    public init(id: String, startAt: Int64, distanceKm: Double, pctPerKm: Double, avgKmh: Double? = nil, climbMPerKm: Double? = nil,
                airTempC: Double? = nil, headwindKmh: Double? = nil) {
        self.id = id
        self.startAt = startAt
        self.distanceKm = distanceKm
        self.pctPerKm = pctPerKm
        self.avgKmh = avgKmh
        self.climbMPerKm = climbMPerKm
        self.airTempC = airTempC
        self.headwindKmh = headwindKmh
    }
}

/// Least squares of y on x, with what the band and the "rides needed" maths need
public struct LinearFit: Equatable, Sendable {
    public var n: Int
    public var slope: Double
    public var intercept: Double
    public var r: Double
    /// residual standard deviation
    public var s: Double
    public var meanX: Double
    public var sxx: Double

    public static func make(_ pts: [(x: Double, y: Double)]) -> LinearFit? {
        let n = pts.count
        guard n >= 3 else { return nil }
        let mx = pts.map(\.x).reduce(0, +) / Double(n)
        let my = pts.map(\.y).reduce(0, +) / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            sxx += (p.x - mx) * (p.x - mx)
            syy += (p.y - my) * (p.y - my)
            sxy += (p.x - mx) * (p.y - my)
        }
        guard sxx > 1e-12 else { return nil }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        let r = syy > 1e-12 ? sxy / (sxx * syy).squareRoot() : 0
        var sse = 0.0
        for p in pts { let e = p.y - (intercept + slope * p.x); sse += e * e }
        let s = n > 2 ? (sse / Double(n - 2)).squareRoot() : 0
        return LinearFit(n: n, slope: slope, intercept: intercept, r: r, s: s, meanX: mx, sxx: sxx)
    }

    public func predict(_ x: Double) -> Double { intercept + slope * x }

    /// Half width of the ~95 % band of the line at x (where the line itself may be)
    public func halfBand(_ x: Double) -> Double {
        1.96 * s * (1 / Double(n) + (x - meanX) * (x - meanX) / sxx).squareRoot()
    }

    /// ~95 % interval of the slope
    public var slopeHalfWidth: Double { sxx > 0 ? 1.96 * s / sxx.squareRoot() : .infinity }

    /// The effect is real at p < 0.05 (|t| ≥ ~2)
    public var isSignificant: Bool { n >= 4 && abs(slope) > slopeHalfWidth }
}

public enum RidesNeeded {
    /// Rides for a correlation r to be significant (p < 0.05, two-sided) with 80 % power (Fisher z); nil when there is no effect to
    /// speak of (|r| < 0.1) or it would take more than 400
    public static func forCorrelation(_ r: Double) -> Int? {
        let a = abs(r)
        guard a >= 0.1, a < 0.999 else { return a >= 0.999 ? 4 : nil }
        let z = 0.5 * log((1 + a) / (1 - a))
        let n = Int(((1.96 + 0.84) / z) * ((1.96 + 0.84) / z) + 3 + 0.999)
        return n > 400 ? nil : max(4, n)
    }

    /// "About 7 more rides" (rounded: to 1 under 10, to 5 under 50, to 10 above)
    public static func moreText(_ more: Int) -> String {
        if more <= 1 { return "About 1 more ride" }
        let rounded = more < 10 ? more : (more < 50 ? Int((Double(more) / 5).rounded()) * 5 : Int((Double(more) / 10).rounded()) * 10)
        return "About \(rounded) more rides"
    }
}

/// One piece of the partial graph: solid where rides cover it, a dashed top / bottom band where data is thin
public struct CurvePiece: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var lo: Double
    public var hi: Double
    public var covered: Bool
}

public struct RideLevelInsight: Equatable, Sendable, Identifiable {
    public enum Topic: String, CaseIterable, Sendable {
        case hills, speedCost, temperature, wind

        public var title: String {
            switch self {
            case .hills: return "What hills cost you"
            case .speedCost: return "What speed costs you"
            case .temperature: return "What cold costs you"
            case .wind: return "What wind costs you"
            }
        }

        /// The range the graph wants to show (x)
        public var wanted: ClosedRange<Double> {
            switch self {
            case .hills: return 0...30
            case .speedCost: return 15...45
            case .temperature: return 0...40
            case .wind: return -20...20
            }
        }

        /// One x step of the graph and of "covered"
        public var step: Double {
            switch self {
            case .hills: return 3
            case .speedCost: return 2.5
            case .temperature: return 4
            case .wind: return 4
            }
        }

        public var unit: String {
            switch self {
            case .hills: return "m climb per km"
            case .speedCost: return "km/h"
            case .temperature: return "\u{00B0}C"
            case .wind: return "km/h headwind"
            }
        }

        /// The x of one ride
        func x(_ r: RideLevelRide) -> Double? {
            switch self {
            case .hills: return r.climbMPerKm
            case .speedCost: return r.avgKmh
            case .temperature: return r.airTempC
            case .wind: return r.headwindKmh
            }
        }

        /// How much x the headline speaks of ("each +1 km/h")
        var per: Double {
            switch self {
            case .hills: return 10
            case .speedCost: return 1
            case .temperature: return -5
            case .wind: return 5
            }
        }

        var perText: String {
            switch self {
            case .hills: return "each +10 m of climb per km"
            case .speedCost: return "each +1 km/h"
            case .temperature: return "each 5 \u{00B0}C colder"
            case .wind: return "each +5 km/h of headwind"
            }
        }
    }

    public var topic: Topic
    public var stage: InsightStage
    public var rides: Int
    /// Rides needed to be confident (nil = no effect to speak of yet)
    public var needed: Int?
    /// "About 7 more rides" / "Waiting for colder days" / "Too early to say"
    public var progressLine: String
    /// From an early read: "+0.02 to +0.08 % per km"
    public var range: String?
    /// "for each +1 km/h"
    public var rangeContext: String?
    /// The partial graph (empty before 3 rides)
    public var curve: [CurvePiece]
    /// One short line for filling the gap, nil when the graph is filled
    public var hint: String?
    /// Riding asks (speed graph only): the ask now, and whether the last one was just done ("Got it ✓")
    public var ask: RidingAsk? = nil
    public var askDone = false
    /// The fitting stretches for the ask, in order ("Not here" moves to the next one)
    public var askStretches: [AskStretch] = []

    public var id: String { topic.rawValue }
    public var title: String { topic.title }

    public var fraction: Double {
        guard let needed, needed > 0 else { return rides > 0 ? min(0.15, Double(rides) / 40) : 0 }
        return min(1, Double(rides) / Double(needed))
    }

    public var earlyMark: Double {
        guard let needed, needed > 0 else { return 0.3 }
        return min(0.9, Double(RideLevelInsights.earlyRides) / Double(needed))
    }
}

public enum RideLevelInsights {
    /// A read starts at this many rides (and an effect at p < 0.25)
    public static let earlyRides = 6
    /// A step of the graph is covered by this many rides
    public static let coverRides = 2
    /// Temperature needs at least this spread of days before it can say anything
    public static let tempSpreadC = 8.0

    /// The order of the Stats list (ride-level and the older engines together)
    public static let order = ["hills", "speedCost", "creep", "temperature", "wind", "departure"]

    public static func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? order.count }

    /// `stretches`: power-measured steady stretches (riding asks, option b): they fill the SPEED graph only
    public static func make(_ topic: RideLevelInsight.Topic, rides: [RideLevelRide], stretches: [StretchPoint] = []) -> RideLevelInsight {
        var pts: [(x: Double, y: Double)] = []
        for r in rides {
            if let x = topic.x(r) { pts.append((x: x, y: r.pctPerKm)) }
        }
        let n = pts.count
        if topic == .speedCost {
            for st in stretches { pts.append((x: st.speedKmh, y: st.pctPerKm)) }
        }
        let xs = pts.map(\.x)
        let fit = LinearFit.make(pts)
        let needed = fit.flatMap { RidesNeeded.forCorrelation($0.r) }
        var stage = InsightStage.learning
        if let f = fit {
            if f.isSignificant, let need = needed, n >= need { stage = .confident }
            else if n >= earlyRides, abs(f.slope) > f.slopeHalfWidth * 0.6 { stage = .early }
        }
        // the progress words, from the real maths
        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
        var line: String
        if topic == .temperature && spread < tempSpreadC {
            let mean = xs.isEmpty ? 25 : xs.reduce(0, +) / Double(xs.count)
            line = mean >= 15 ? "Waiting for colder days" : "Waiting for warmer days"
        } else if n < 4 {
            line = RidesNeeded.moreText(4 - n) + " for a first read"
        } else if let need = needed {
            line = n >= need ? (stage == .confident ? "Confident" : RidesNeeded.moreText(5)) : RidesNeeded.moreText(need - n)
        } else {
            line = "Too early to say how many rides"
        }
        // the early read's range of the effect per step
        var range: String?
        var context: String?
        if stage != .learning, let f = fit {
            let a = (f.slope - f.slopeHalfWidth) * topic.per, b = (f.slope + f.slopeHalfWidth) * topic.per
            if let clear = clearRange(min(a, b), max(a, b)) {
                range = clear
                context = "for " + topic.perText
            } else {
                // N4-4 (B85): an interval that touches or crosses 0 says nothing yet (and never "speed saves battery")
                range = noClearCost
                context = "less than \(bound(max(abs(a), abs(b)))) % per km for \(topic.perText) so far"
            }
        }
        let curve = fit.map { partialCurve(topic, fit: $0, xs: xs) } ?? []
        return RideLevelInsight(topic: topic, stage: stage, rides: n, needed: needed, progressLine: line, range: range,
                                rangeContext: context, curve: curve, hint: hint(topic, xs: xs))
    }

    public static func all(_ rides: [RideLevelRide]) -> [RideLevelInsight] {
        RideLevelInsight.Topic.allCases.map { make($0, rides: rides) }
    }

    static func signed(_ v: Double) -> String {
        let t = String(format: "%.2f", abs(v))
        if t == "0.00" { return "0" }          // N4-4 (B85): never "−0.00"
        return (v < 0 ? "\u{2212}" : "+") + t
    }

    /// N4-4 (B85): the headline when the early read's interval touches or crosses 0 (after rounding)
    public static let noClearCost = "No clear cost yet"

    /// "+0.02 to +0.08 % per km", nil when the rounded interval touches or crosses 0
    static func clearRange(_ lo: Double, _ hi: Double) -> String? {
        let l = (lo * 100).rounded() / 100, h = (hi * 100).rounded() / 100
        guard (l > 0 && h > 0) || (l < 0 && h < 0) else { return nil }
        return "\(signed(lo)) to \(signed(hi)) % per km"
    }

    /// The upper bound of a small effect, rounded up to 0.01 ("0.02")
    static func bound(_ v: Double) -> String { String(format: "%.2f", max(0.01, (v * 100).rounded(.up) / 100)) }

    /// Steps over the wanted range (and the data); covered = at least `coverRides` rides within half a step
    public static func covered(_ topic: RideLevelInsight.Topic, xs: [Double]) -> [(x: Double, covered: Bool)] {
        let lo = min(topic.wanted.lowerBound, xs.min() ?? topic.wanted.lowerBound)
        let hi = max(topic.wanted.upperBound, xs.max() ?? topic.wanted.upperBound)
        var out: [(Double, Bool)] = []
        var x = lo
        while x <= hi + 1e-9 {
            let near = xs.filter { abs($0 - x) <= topic.step / 2 + 1e-9 }.count
            out.append((x, near >= coverRides))
            x += topic.step
        }
        return out
    }

    static func partialCurve(_ topic: RideLevelInsight.Topic, fit: LinearFit, xs: [Double]) -> [CurvePiece] {
        covered(topic, xs: xs).map { c in
            let y = fit.predict(c.x)
            let h = fit.halfBand(c.x)
            return CurvePiece(x: c.x, y: y, lo: max(0, y - h), hi: y + h, covered: c.covered)
        }
    }

    /// The widest gap of the wanted range as one short line (nil when it is filled)
    public static func hint(_ topic: RideLevelInsight.Topic, xs: [Double]) -> String? {
        let steps = covered(topic, xs: xs).filter { topic.wanted.contains($0.x) }
        var best: (from: Double, to: Double)?
        var start: Double?
        var last: Double?
        for s in steps {
            if !s.covered {
                if start == nil { start = s.x }
                last = s.x
            } else if let a = start, let b = last {
                if best == nil || b - a > best!.to - best!.from { best = (a, b) }
                start = nil
            }
        }
        if let a = start, let b = last, best == nil || b - a > best!.to - best!.from { best = (a, b) }
        guard let gap = best else { return nil }
        let mean = xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        switch topic {
        case .speedCost:
            return "Ride steady at \(Int(gap.from.rounded()))\u{2013}\(Int(max(gap.to, gap.from + topic.step).rounded())) km/h to fill this in."
        case .hills:
            return (mean ?? 0) > (gap.from + gap.to) / 2 ? "Flatter rides will fill this in." : "Rides with more climbing will fill this in."
        case .temperature:
            return (mean ?? 25) > (gap.from + gap.to) / 2 ? "Colder days will fill this in." : "Warmer days will fill this in."
        case .wind:
            return gap.to <= 0 ? "Days with the wind behind you will fill this in." : "Windy days will fill this in."
        }
    }
}
