import Foundation

// T-00 part 2 (P6_PLAN section 2, point 1): the prediction log. Every estimate the app shows is stored with the
// number it showed; when the ride is closed the actual number is filled in. This file is the pure part: which stored
// prediction belongs to which ride (`PredictionSettler`), and the median / p90 error per P6 question (`AccuracyCalc`).
// Shown numbers stay honest (no safety margin): the log compares what was shown with what happened.

/// The kinds of prediction in the log (strings, because they are stored).
public enum PredictionKind {
    /// Q-C: Today's time for the route, seconds (route card, Where to? chip)
    public static let time = "time"
    /// Q-D: Today's battery use, points
    public static let battery = "battery"
    /// Q-E: the arrival time shown at 25 / 50 / 75% of a followed ride, epoch ms
    public static let eta25 = "eta25"
    public static let eta50 = "eta50"
    public static let eta75 = "eta75"
    /// Q-F: the real range shown at ride start, km (`aux` = usable points: battery % minus the reserve)
    public static let range = "range"
    /// Q-G: Wh per 1% the calibration used at ride start
    public static let calib = "calib"
    /// There-and-back card: the battery % expected at the destination
    public static let thereBack = "thereBack"

    public static let preRide = [time, battery, thereBack]
    public static let inRide = [eta25, eta50, eta75, range, calib]

    public static func eta(percent: Int) -> String { "eta\(percent)" }
}

/// A stored prediction waiting for its ride.
public struct OpenPrediction: Equatable, Sendable {
    public var id: Int64
    public var kind: String
    public var routeId: String?
    public var madeAt: Int64
    public var predicted: Double
    public var aux: Double?

    public init(id: Int64, kind: String, routeId: String?, madeAt: Int64, predicted: Double, aux: Double? = nil) {
        self.id = id
        self.kind = kind
        self.routeId = routeId
        self.madeAt = madeAt
        self.predicted = predicted
        self.aux = aux
    }
}

/// What the closed ride gives the log.
public struct SettledRide: Equatable, Sendable {
    public var id: String
    public var routeId: String?
    public var startAt: Int64
    public var endAt: Int64
    public var lastMoveAt: Int64?
    public var totalS: Double?
    public var distanceM: Double?
    public var usedPct: Double?
    public var startRestPct: Double?
    public var endRestPct: Double?
    public var energyWhRaw: Double?

    public init(id: String, routeId: String?, startAt: Int64, endAt: Int64, lastMoveAt: Int64? = nil, totalS: Double? = nil,
                distanceM: Double? = nil, usedPct: Double? = nil, startRestPct: Double? = nil, endRestPct: Double? = nil,
                energyWhRaw: Double? = nil) {
        self.id = id
        self.routeId = routeId
        self.startAt = startAt
        self.endAt = endAt
        self.lastMoveAt = lastMoveAt
        self.totalS = totalS
        self.distanceM = distanceM
        self.usedPct = usedPct
        self.startRestPct = startRestPct
        self.endRestPct = endRestPct
        self.energyWhRaw = energyWhRaw
    }

    /// Battery used by the ride: the rested drop when both rested readings exist, else the stored used %.
    public var usedPoints: Double? {
        if let a = startRestPct, let b = endRestPct, a >= b { return a - b }
        return usedPct
    }
}

public struct PredictionSettlement: Equatable, Sendable {
    public var predictionId: Int64
    public var actual: Double
}

public struct PredictionSettleResult: Equatable, Sendable {
    public var settled: [PredictionSettlement] = []
    /// belonged to the ride but cannot be judged (e.g. no rested battery readings): removed from the log
    public var dropIds: [Int64] = []
}

public enum PredictionSettler {
    /// Estimates shown up to this long before the ride start count for the ride (a morning check of Today)
    public static let lookBackMs: Int64 = 6 * 3_600_000
    /// A ride is judged on its battery only when it used at least this many points (rounding makes less meaningless)
    public static let minUsedPoints = 5.0
    public static let minRangeKm = 1.0
    /// Unsettled predictions older than this are deleted
    public static let expiryMs: Int64 = 7 * 86_400_000

    /// The newest prediction of each kind that belongs to the ride, with its actual number.
    public static func settle(open: [OpenPrediction], ride: SettledRide) -> PredictionSettleResult {
        var out = PredictionSettleResult()
        var belongs: [OpenPrediction] = []
        for p in open {
            if PredictionKind.preRide.contains(p.kind) {
                guard let route = ride.routeId, p.routeId == route else { continue }
                guard p.madeAt <= ride.startAt + 60_000, p.madeAt >= ride.startAt - lookBackMs else { continue }
            } else {
                guard p.madeAt >= ride.startAt - 60_000, p.madeAt <= ride.endAt + 60_000 else { continue }
            }
            belongs.append(p)
        }
        // one per kind: the newest; the older ones of the same kind are dropped
        for kind in Set(belongs.map(\.kind)) {
            let ofKind = belongs.filter { $0.kind == kind }.sorted { $0.madeAt > $1.madeAt }
            guard let newest = ofKind.first else { continue }
            out.dropIds += ofKind.dropFirst().map(\.id)
            if let actual = actual(newest, ride: ride) {
                out.settled.append(PredictionSettlement(predictionId: newest.id, actual: actual))
            } else {
                out.dropIds.append(newest.id)
            }
        }
        out.settled.sort { $0.predictionId < $1.predictionId }
        out.dropIds.sort()
        return out
    }

    static func actual(_ p: OpenPrediction, ride: SettledRide) -> Double? {
        switch p.kind {
        case PredictionKind.time:
            guard let t = ride.totalS, t > 0 else { return nil }
            return t
        case PredictionKind.battery:
            guard let u = ride.usedPoints else { return nil }
            return u
        case PredictionKind.thereBack:
            return ride.endRestPct
        case PredictionKind.eta25, PredictionKind.eta50, PredictionKind.eta75:
            return Double(ride.lastMoveAt ?? ride.endAt)
        case PredictionKind.range:
            guard let u = ride.usedPoints, u >= minUsedPoints, let d = ride.distanceM, d / 1000 >= minRangeKm, let usable = p.aux, usable > 0 else { return nil }
            return usable * (d / 1000) / u
        case PredictionKind.calib:
            guard let a = ride.startRestPct, let b = ride.endRestPct, a - b >= T.t41CalibrationDropPct, let e = ride.energyWhRaw, e > 0 else { return nil }
            return e / (a - b)
        default:
            return nil
        }
    }
}

// MARK: Accuracy

public struct PredictionRow: Equatable, Sendable {
    public var kind: String
    public var predicted: Double
    public var actual: Double?
    public var madeAt: Int64

    public init(kind: String, predicted: Double, actual: Double?, madeAt: Int64) {
        self.kind = kind
        self.predicted = predicted
        self.actual = actual
        self.madeAt = madeAt
    }
}

public struct AccuracyLine: Equatable, Sendable, Identifiable {
    public enum Verdict: String, Sendable { case noData, tooFew, met, notYet, info }

    public var id: String { kind }
    public var question: String
    public var title: String
    public var kind: String
    public var unit: String
    /// Number of settled predictions the numbers are based on
    public var n: Int
    public var median: Double?
    public var p90: Double?
    /// The P6 target for the median error (nil = recorded only)
    public var target: Double?
    public var targetText: String
    public var verdict: Verdict

    public var verdictText: String {
        switch verdict {
        case .noData: return "no data yet"
        case .tooFew: return "too few to judge"
        case .met: return "target met"
        case .notYet: return "target not met"
        case .info: return "recorded"
        }
    }

    /// "median 0.8 min · p90 2.1 min"
    public var errorText: String {
        guard let m = median, let p = p90 else { return "-" }
        return "median \(AccuracyCalc.number(m)) \(unit) \u{00B7} p90 \(AccuracyCalc.number(p)) \(unit)"
    }
}

public enum AccuracyCalc {
    /// At least this many settled predictions before a line says met / not met
    public static let minForVerdict = 5
    /// Q-G counts the rides after the first five (the calibration is still learning before)
    public static let calibrationLearningRides = T.t41CalibrationRides

    struct Def {
        var question: String
        var title: String
        var kind: String
        var unit: String
        var target: Double?
        var targetText: String
        var skipFirst = 0
    }

    static let defs: [Def] = [
        Def(question: "Q-C", title: "Today's time estimate", kind: PredictionKind.time, unit: "min", target: 1.5, targetText: "median error \u{2264} 1.5 min"),
        Def(question: "Q-D", title: "Today's battery estimate", kind: PredictionKind.battery, unit: "points", target: 3, targetText: "median error \u{2264} 3 points"),
        Def(question: "Q-E", title: "Arrival time at 25% of the ride", kind: PredictionKind.eta25, unit: "min", target: nil, targetText: "recorded only"),
        Def(question: "Q-E", title: "Arrival time at 50% of the ride", kind: PredictionKind.eta50, unit: "min", target: 1, targetText: "median error \u{2264} 1 min"),
        Def(question: "Q-E", title: "Arrival time at 75% of the ride", kind: PredictionKind.eta75, unit: "min", target: nil, targetText: "recorded only"),
        Def(question: "Q-F", title: "Real range at ride start", kind: PredictionKind.range, unit: "%", target: 10, targetText: "median error \u{2264} 10%"),
        Def(question: "Q-G", title: "Wh per 1% (calibration) after 5 rides", kind: PredictionKind.calib, unit: "%", target: 5, targetText: "median error \u{2264} 5%",
            skipFirst: T.t41CalibrationRides),
        Def(question: "Q-C/D", title: "There and back: battery at the destination", kind: PredictionKind.thereBack, unit: "points", target: 3,
            targetText: "median error \u{2264} 3 points")
    ]

    /// The error of one prediction in the line's unit (always positive).
    public static func error(kind: String, predicted: Double, actual: Double) -> Double? {
        switch kind {
        case PredictionKind.time: return abs(predicted - actual) / 60
        case PredictionKind.battery, PredictionKind.thereBack: return abs(predicted - actual)
        case PredictionKind.eta25, PredictionKind.eta50, PredictionKind.eta75: return abs(predicted - actual) / 60_000
        case PredictionKind.range, PredictionKind.calib: return actual > 0 ? abs(predicted - actual) / actual * 100 : nil
        default: return nil
        }
    }

    public static func lines(_ rows: [PredictionRow]) -> [AccuracyLine] {
        defs.map { d in
            var settled = rows.filter { $0.kind == d.kind && $0.actual != nil }.sorted { $0.madeAt < $1.madeAt }
            if d.skipFirst > 0 { settled = Array(settled.dropFirst(d.skipFirst)) }
            let errors = settled.compactMap { r in r.actual.flatMap { error(kind: d.kind, predicted: r.predicted, actual: $0) } }
            let med = median(errors)
            let p90 = percentile(errors, 0.9)
            let verdict: AccuracyLine.Verdict
            if errors.isEmpty { verdict = .noData }
            else if d.target == nil { verdict = .info }
            else if errors.count < minForVerdict { verdict = .tooFew }
            else if let m = med, let t = d.target { verdict = m <= t ? .met : .notYet }
            else { verdict = .noData }
            return AccuracyLine(question: d.question, title: d.title, kind: d.kind, unit: d.unit, n: errors.count, median: med, p90: p90,
                                target: d.target, targetText: d.targetText, verdict: verdict)
        }
    }

    /// accuracy.txt
    public static func text(_ rows: [PredictionRow], now: String) -> String {
        var out = "Accuracy (prediction log) \u{00B7} \(now)\n"
        out += "Every estimate the app showed, compared with what the ride then did. Shown numbers, no safety margin.\n\n"
        for l in lines(rows) {
            out += "\(l.question) \(l.title)\n"
            out += "  based on \(l.n) \(l.n == 1 ? "ride" : "rides") \u{00B7} \(l.errorText) \u{00B7} target: \(l.targetText) \u{00B7} \(l.verdictText)\n"
        }
        let open = rows.filter { $0.actual == nil }.count
        out += "\n\(rows.count - open) settled, \(open) waiting for a ride\n"
        return out
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Nearest-rank percentile
    public static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let idx = min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))
        return s[idx]
    }

    public static func number(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
