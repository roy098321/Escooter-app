import Foundation

/// F-21: the small statistics behind the insights (weighted least squares with its covariance, a robust refit, Welch's difference of
/// two means, a kernel mean with its band) and the certainty gate. Pure, unit tested.
public enum InsightMath {
    /// A least-squares fit: the coefficients, their covariance and the residual spread.
    public struct Fit: Equatable, Sendable {
        public var beta: [Double]
        public var cov: [[Double]]
        /// Residual standard deviation (weighted)
        public var sigma: Double
        public var n: Int
        public var dof: Int { max(1, n - beta.count) }

        /// The standard error of coefficient `i`
        public func se(_ i: Int) -> Double { sqrt(max(0, cov[i][i])) }

        /// beta[i] / se(i); 0 when the error is 0
        public func t(_ i: Int) -> Double {
            let s = se(i)
            return s > 0 ? beta[i] / s : 0
        }

        public func predict(_ row: [Double]) -> Double { zip(row, beta).reduce(0.0) { $0 + $1.0 * $1.1 } }

        /// The standard error of the fitted mean at `row`
        public func predictSE(_ row: [Double]) -> Double {
            var v = 0.0
            for i in 0..<row.count {
                for j in 0..<row.count { v += row[i] * cov[i][j] * row[j] }
            }
            return sqrt(max(0, v))
        }
    }

    /// Weighted least squares y = Σ beta_k · row_k (no intercept added: put a 1 in the rows). nil: too few rows or a singular system.
    public static func leastSquares(rows: [[Double]], y: [Double], weights: [Double]? = nil) -> Fit? {
        let n = rows.count
        guard n == y.count, let k = rows.first?.count, k > 0, n > k else { return nil }
        let w = weights ?? [Double](repeating: 1, count: n)
        guard w.count == n else { return nil }
        // weights scaled to a mean of 1, so sigma is in the units of y
        let wSum = w.reduce(0, +)
        guard wSum > 0 else { return nil }
        let ws = w.map { $0 * Double(n) / wSum }
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var xty = [Double](repeating: 0, count: k)
        for r in 0..<n {
            for i in 0..<k {
                xty[i] += ws[r] * rows[r][i] * y[r]
                for j in 0..<k { xtx[i][j] += ws[r] * rows[r][i] * rows[r][j] }
            }
        }
        guard let inv = invert(xtx) else { return nil }
        var beta = [Double](repeating: 0, count: k)
        for i in 0..<k {
            for j in 0..<k { beta[i] += inv[i][j] * xty[j] }
        }
        var rss = 0.0
        for r in 0..<n {
            let res = y[r] - zip(rows[r], beta).reduce(0.0) { $0 + $1.0 * $1.1 }
            rss += ws[r] * res * res
        }
        let s2 = rss / Double(n - k)
        let cov = inv.map { $0.map { $0 * s2 } }
        return Fit(beta: beta, cov: cov, sigma: sqrt(s2), n: n)
    }

    /// The same fit, then once more without the rows further than 3 robust deviations from it (a stretch with a gust, a wrong reading).
    public static func robustLeastSquares(rows: [[Double]], y: [Double], weights: [Double]? = nil) -> (fit: Fit, kept: [Int])? {
        guard let first = leastSquares(rows: rows, y: y, weights: weights) else { return nil }
        let res = (0..<rows.count).map { y[$0] - first.predict(rows[$0]) }
        guard let mad = median(res.map { abs($0) }), mad > 0 else { return (first, Array(0..<rows.count)) }
        let limit = 3 * 1.4826 * mad
        let kept = (0..<rows.count).filter { abs(res[$0]) <= limit }
        let keptN = kept.count, allN = rows.count, needN = (rows.first?.count ?? 0) + 2
        guard allN > keptN, keptN > needN else { return (first, Array(0..<allN)) }
        let w = weights.map { ws in kept.map { ws[$0] } }
        guard let second = leastSquares(rows: kept.map { rows[$0] }, y: kept.map { y[$0] }, weights: w) else { return (first, Array(0..<rows.count)) }
        return (second, kept)
    }

    /// Gauss-Jordan inverse; nil when singular
    static func invert(_ m: [[Double]]) -> [[Double]]? {
        let k = m.count
        var a = m
        var inv = (0..<k).map { i in (0..<k).map { j in i == j ? 1.0 : 0.0 } }
        for col in 0..<k {
            var pivot = col
            for r in col..<k where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            inv.swapAt(col, pivot)
            let p = a[col][col]
            for j in 0..<k {
                a[col][j] /= p
                inv[col][j] /= p
            }
            for r in 0..<k where r != col {
                let f = a[r][col]
                if f == 0 { continue }
                for j in 0..<k {
                    a[r][j] -= f * a[col][j]
                    inv[r][j] -= f * inv[col][j]
                }
            }
        }
        return inv
    }

    /// Two-sided 95 % Student t quantile (a short table; large samples ~1.98)
    public static func tCrit(_ dof: Int) -> Double {
        let table: [Double] = [12.71, 4.30, 3.18, 2.78, 2.57, 2.45, 2.36, 2.31, 2.26, 2.23]
        if dof <= 0 { return 12.71 }
        if dof <= 10 { return table[dof - 1] }
        if dof <= 15 { return 2.13 }
        if dof <= 20 { return 2.09 }
        if dof <= 30 { return 2.04 }
        return 1.98
    }

    public static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Sample variance (n − 1)
    public static func variance(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        return v.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)
    }

    /// Welch: mean(a) − mean(b), its standard error and the degrees of freedom. nil below 2 values each.
    public static func meanDifference(_ a: [Double], _ b: [Double]) -> (diff: Double, se: Double, dof: Int)? {
        guard let ma = mean(a), let mb = mean(b), let va = variance(a), let vb = variance(b) else { return nil }
        let qa = va / Double(a.count), qb = vb / Double(b.count)
        let se = sqrt(qa + qb)
        let den = (qa * qa) / Double(a.count - 1) + (qb * qb) / Double(b.count - 1)
        let dof = den > 0 ? Int(((qa + qb) * (qa + qb) / den).rounded(.down)) : a.count + b.count - 2
        return (ma - mb, se, max(1, dof))
    }

    /// Gaussian-kernel mean of `ys` at `x` (bandwidth `bw`), its standard error and the effective number of points behind it
    public static func kernelMean(xs: [Double], ys: [Double], at x: Double, bw: Double) -> (mean: Double, se: Double, nEff: Double)? {
        guard xs.count == ys.count, !xs.isEmpty, bw > 0 else { return nil }
        let w = xs.map { exp(-0.5 * pow(($0 - x) / bw, 2)) }
        let sw = w.reduce(0, +)
        guard sw > 1e-9 else { return nil }
        let m = zip(w, ys).reduce(0.0) { $0 + $1.0 * $1.1 } / sw
        let sw2 = w.reduce(0.0) { $0 + $1 * $1 }
        let nEff = sw * sw / sw2
        let v = zip(w, ys).reduce(0.0) { $0 + $1.0 * ($1.1 - m) * ($1.1 - m) } / sw
        let se = nEff > 1 ? sqrt(v * nEff / (nEff - 1) / nEff) : .infinity
        return (m, se, nEff)
    }
}

/// F-21 certainty gate: an insight is shown only at Medium or High. Medium = enough samples and the effect's 95 % interval excludes
/// "no difference" (|t| ≥ 2); High = more samples and |t| ≥ 3. Per-kind sample sizes are below.
public enum InsightGate {
    public static let mediumT = 2.0
    public static let highT = 3.0

    /// Speed sweet spot: steady stretches and rides behind the curve, and the sweet spot interval half-width (km/h)
    public static let sweetMediumStretches = 12, sweetHighStretches = 30
    public static let sweetMediumRides = 4, sweetHighRides = 8
    public static let sweetMediumHalfWidthKmh = 4.0, sweetHighHalfWidthKmh = 2.5

    /// Departure time: rides in each of the two windows compared
    public static let departMediumPerWindow = 3, departHighPerWindow = 6
    /// smaller than this is not worth a card, s
    public static let departMinGainS = 120.0

    /// Battery-use creep: recent and reference rides on the same routes
    public static let creepMediumRides = 8, creepHighRides = 12
    /// High also needs all 10 recent rides
    public static let creepRecentHigh = 10
    /// smaller than this is not worth a card, share of the reference %/km
    public static let creepMinShare = 0.05

    /// Today's wind: rides with a headwind value behind the wind cost
    public static let windMediumRides = 8, windHighRides = 15

    /// The generic rule: n against the two sample sizes, |t| against 2 and 3
    public static func level(n: Int, mediumN: Int, highN: Int, t: Double) -> CertaintyLevel {
        let at = abs(t)
        if n >= highN, at >= highT { return .high }
        if n >= mediumN, at >= mediumT { return .medium }
        return .low
    }

    /// Sweet spot: the curve must bend up (curvature t), enough stretches from enough rides, and a narrow enough interval
    public static func sweetSpot(stretches: Int, rides: Int, curvatureT: Double, halfWidthKmh: Double) -> CertaintyLevel {
        guard curvatureT > 0 else { return .low }
        if stretches >= sweetHighStretches, rides >= sweetHighRides, curvatureT >= highT, halfWidthKmh <= sweetHighHalfWidthKmh { return .high }
        if stretches >= sweetMediumStretches, rides >= sweetMediumRides, curvatureT >= mediumT, halfWidthKmh <= sweetMediumHalfWidthKmh { return .medium }
        return .low
    }

    /// Departure: both windows need their rides and the gain must be worth it
    public static func departure(bestN: Int, habitN: Int, gainS: Double, t: Double) -> CertaintyLevel {
        guard gainS >= departMinGainS else { return .low }
        return level(n: min(bestN, habitN), mediumN: departMediumPerWindow, highN: departHighPerWindow, t: t)
    }

    /// Creep: only an increase of 5 % or more counts
    public static func creep(recentN: Int, referenceN: Int, share: Double, t: Double) -> CertaintyLevel {
        guard share >= creepMinShare, t > 0 else { return .low }
        if recentN >= creepRecentHigh, referenceN >= creepHighRides, t >= highT { return .high }
        if recentN >= creepMediumRides, referenceN >= creepMediumRides, t >= mediumT { return .medium }
        return .low
    }

    /// Wind: the slope of battery per km on headwind must be positive and clear
    public static func wind(rides: Int, slopeT: Double) -> CertaintyLevel {
        guard slopeT > 0 else { return .low }
        return level(n: rides, mediumN: windMediumRides, highN: windHighRides, t: slopeT)
    }
}

/// F-21 text helpers (one decimal, the real minus sign, month and day)
public enum InsightFormat {
    public static let minus = "\u{2212}"

    public static func one(_ v: Double) -> String { String(format: "%.1f", v) }

    public static func two(_ v: Double) -> String { String(format: "%.2f", v) }

    /// "+3", "−5", "0"
    public static func signedInt(_ v: Int) -> String {
        v > 0 ? "+\(v)" : (v < 0 ? minus + "\(-v)" : "0")
    }

    /// "7:40" from minutes after midnight
    public static func clock(_ minuteOfDay: Double) -> String {
        let m = (Int(minuteOfDay.rounded()) % 1440 + 1440) % 1440
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// "Sep 28 – Oct 19" (en dash) from two ms times, in the given offset
    public static func span(fromMs: Int64, toMs: Int64, utcOffsetMin: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        df.dateFormat = "MMM d"
        let a = df.string(from: Date(timeIntervalSince1970: Double(fromMs) / 1000))
        let b = df.string(from: Date(timeIntervalSince1970: Double(toMs) / 1000))
        return a == b ? a : "\(a) \u{2013} \(b)"
    }

    /// "September" for a ms time
    public static func month(_ ms: Int64, utcOffsetMin: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        df.dateFormat = "MMMM"
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Nice axis ticks: about `count` round values covering lo...hi
    public static func ticks(_ lo: Double, _ hi: Double, count: Int = 4) -> [Double] {
        guard hi > lo, count > 1 else { return [lo] }
        let raw = (hi - lo) / Double(count - 1)
        let mag = pow(10, floor(log10(raw)))
        let steps = [1.0, 2.0, 2.5, 5.0, 10.0]
        let step = (steps.first { $0 * mag >= raw } ?? 10) * mag
        var out: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v <= hi + 1e-9 {
            out.append(v)
            v += step
        }
        return out
    }
}
