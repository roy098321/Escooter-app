import Foundation

/// One reading as the sweet spot needs it (from `ride_sample`)
public struct SpeedSample: Equatable, Sendable {
    /// seconds from the ride start
    public var tS: Double
    public var speedKmh: Double?
    /// V × I (or the scooter's power), W
    public var powerW: Double?
    /// barometric or GPS altitude, m
    public var altM: Double?

    public init(tS: Double, speedKmh: Double?, powerW: Double?, altM: Double? = nil) {
        self.tS = tS
        self.speedKmh = speedKmh
        self.powerW = powerW
        self.altM = altM
    }
}

/// One ride with its readings
public struct SweetSpotRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var distanceKm: Double
    /// strong wind on the ride (left out)
    public var strongWind: Bool
    public var samples: [SpeedSample]

    public init(id: String, startAt: Int64, distanceKm: Double, strongWind: Bool, samples: [SpeedSample]) {
        self.id = id
        self.startAt = startAt
        self.distanceKm = distanceKm
        self.strongWind = strongWind
        self.samples = samples
    }
}

/// At least a minute at a near-constant speed
public struct SteadyStretch: Equatable, Sendable {
    public var rideId: String
    public var speedKmh: Double
    public var whPerKm: Double
    public var km: Double

    public init(rideId: String, speedKmh: Double, whPerKm: Double, km: Double) {
        self.rideId = rideId
        self.speedKmh = speedKmh
        self.whPerKm = whPerKm
        self.km = km
    }
}

/// What the sweet spot needs besides the rides
public struct SweetSpotContext: Equatable, Sendable {
    /// Wh per battery % (the calibration)
    public var whPerPct: Double
    /// The honest battery % per km of whole recent rides (RealRange), nil = from the curve
    public var usualPctPerKm: Double?
    public var reservePct: Double
    /// The usual route: "Work" (for "to Work"), its km and usual time
    public var destination: String?
    public var routeKm: Double?
    public var routeTimeS: Double?
    public var utcOffsetMin: Int

    public init(whPerPct: Double, usualPctPerKm: Double?, reservePct: Double, destination: String?, routeKm: Double?, routeTimeS: Double?,
                utcOffsetMin: Int) {
        self.whPerPct = whPerPct
        self.usualPctPerKm = usualPctPerKm
        self.reservePct = reservePct
        self.destination = destination
        self.routeKm = routeKm
        self.routeTimeS = routeTimeS
        self.utcOffsetMin = utcOffsetMin
    }
}

/// F-21 speed sweet spot (PATTERN): battery % per km by speed from steady stretches, a robust quadratic through them, its lowest point
/// with an interval (delta method), and what cruising 5 / 10 km/h slower or faster does to the range from full and the usual trip.
public enum SweetSpotInsight {
    public static let minKmh = 10.0
    /// a stretch: speed within ±2.5 km/h of its running mean, readings at most 3 s apart, 60–120 s long
    public static let steadyBandKmh = 2.5
    public static let maxGapS = 3.0
    public static let minStretchS = 60.0
    public static let maxStretchS = 120.0
    /// a climb (or a descent): more than 2 % average grade over the stretch
    public static let climbGrade = 0.02

    public struct Cuts: Equatable, Sendable {
        public var climbs = 0
        public var windyRides = 0
        public var noPower = 0
        public init() {}
    }

    /// The steady stretches of one ride's readings (speed, power, altitude); counts what was left out
    public static func stretches(rideId: String, samples: [SpeedSample], cuts: inout Cuts) -> [SteadyStretch] {
        var out: [SteadyStretch] = []
        var seg: [SpeedSample] = []
        var sum = 0.0

        func emit() {
            defer {
                seg = []
                sum = 0
            }
            guard let first = seg.first, let last = seg.last, last.tS - first.tS >= minStretchS else { return }
            var wh = 0.0, km = 0.0, withPower = 0
            for i in 1..<seg.count {
                let dt = seg[i].tS - seg[i - 1].tS
                let v1: Double = seg[i].speedKmh ?? 0
                let v0: Double = seg[i - 1].speedKmh ?? 0
                let meanKmh: Double = (v1 + v0) / 2
                km += dt * meanKmh / 3600
                if let p = seg[i - 1].powerW {
                    wh += p * dt / 3600
                    withPower += 1
                }
            }
            guard Double(withPower) >= 0.8 * Double(seg.count - 1) else {
                cuts.noPower += 1
                return
            }
            guard km > 0.05 else { return }
            if let a = first.altM, let b = last.altM, abs(b - a) / (km * 1000) > climbGrade {
                cuts.climbs += 1
                return
            }
            guard wh > 0 else { return }
            out.append(SteadyStretch(rideId: rideId, speedKmh: km / ((last.tS - first.tS) / 3600), whPerKm: wh / km, km: km))
        }

        for s in samples.sorted(by: { $0.tS < $1.tS }) {
            guard let v = s.speedKmh, v >= minKmh else {
                emit()
                continue
            }
            if let last = seg.last, s.tS - last.tS > maxGapS { emit() }
            if !seg.isEmpty, abs(v - sum / Double(seg.count)) > steadyBandKmh { emit() }
            seg.append(s)
            sum += v
            if let first = seg.first, s.tS - first.tS >= maxStretchS { emit() }
        }
        emit()
        return out
    }

    /// The fitted curve: battery % per km at speed x
    public struct Curve: Equatable, Sendable {
        public var fit: InsightMath.Fit
        /// the speed the fit is centred on
        public var x0: Double

        public func row(_ x: Double) -> [Double] { [1, x - x0, (x - x0) * (x - x0)] }
        public func y(_ x: Double) -> Double { fit.predict(row(x)) }
        public func se(_ x: Double) -> Double { fit.predictSE(row(x)) }

        /// The lowest point, nil when the curve does not bend up
        public var minimum: Double? {
            let c = fit.beta[2]
            guard c > 0 else { return nil }
            return x0 - fit.beta[1] / (2 * c)
        }

        /// Standard error of the lowest point (delta method)
        public var minimumSE: Double {
            let b = fit.beta[1], c = fit.beta[2]
            guard c > 0 else { return .infinity }
            let g = [0, -1 / (2 * c), b / (2 * c * c)]
            var v = 0.0
            for i in 0..<3 {
                for j in 0..<3 { v += g[i] * fit.cov[i][j] * g[j] }
            }
            return sqrt(max(0, v))
        }
    }

    /// A robust, km-weighted quadratic of %/km on speed
    public static func curve(_ stretches: [SteadyStretch], whPerPct: Double) -> Curve? {
        guard stretches.count >= 5, whPerPct > 0 else { return nil }
        let wSum = stretches.reduce(0.0) { $0 + $1.km }
        guard wSum > 0 else { return nil }
        let x0 = stretches.reduce(0.0) { $0 + $1.speedKmh * $1.km } / wSum
        let rows = stretches.map { [1, $0.speedKmh - x0, ($0.speedKmh - x0) * ($0.speedKmh - x0)] }
        let y = stretches.map { $0.whPerKm / whPerPct }
        guard let r = InsightMath.robustLeastSquares(rows: rows, y: y, weights: stretches.map(\.km)) else { return nil }
        return Curve(fit: r.fit, x0: x0)
    }

    /// km-weighted median speed: how the rider usually cruises
    public static func usualCruise(_ stretches: [SteadyStretch]) -> Double? {
        let s = stretches.sorted { $0.speedKmh < $1.speedKmh }
        let total = s.reduce(0.0) { $0 + $1.km }
        guard total > 0 else { return nil }
        var acc = 0.0
        for x in s {
            acc += x.km
            if acc >= total / 2 { return x.speedKmh }
        }
        return s.last?.speedKmh
    }

    public static func make(rides: [SweetSpotRide], context: SweetSpotContext) -> InsightOutcome {
        var cuts = Cuts()
        var all: [SteadyStretch] = []
        var used: [SweetSpotRide] = []
        for r in rides {
            if r.strongWind {
                cuts.windyRides += 1
                continue
            }
            let found = stretches(rideId: r.id, samples: r.samples, cuts: &cuts)
            if !found.isEmpty {
                all += found
                used.append(r)
            }
        }
        let rideCount = used.count
        guard all.count >= InsightGate.sweetMediumStretches, rideCount >= InsightGate.sweetMediumRides else {
            return .learning(.sweetSpot, "\(all.count) of \(InsightGate.sweetMediumStretches) steady stretches")
        }
        guard let fitted = curve(all, whPerPct: context.whPerPct), let best = fitted.minimum,
              let lo = all.map(\.speedKmh).min(), let hi = all.map(\.speedKmh).max(), best >= lo, best <= hi,
              let cruise = usualCruise(all) else {
            return .learning(.sweetSpot, "no clear lowest point yet")
        }
        let tq = InsightMath.tCrit(fitted.fit.dof)
        let half = tq * fitted.minimumSE
        let level = InsightGate.sweetSpot(stretches: all.count, rides: rideCount, curvatureT: fitted.fit.t(2), halfWidthKmh: half)

        let bestInt = Int(best.rounded())
        let base = Double(Int(cruise.rounded()))
        let yBest = fitted.y(best)
        // the comparison: the fast end of what the rider rides
        let speeds = all.map(\.speedKmh).sorted()
        let p90 = speeds[min(speeds.count - 1, Int(Double(speeds.count) * 0.9))]
        var fast = p90.rounded()
        if fast - best < 4 { fast = min(hi, best + 10).rounded() }
        let yFast = fitted.y(fast)

        // range from full (honest, no margin): the usual whole-ride %/km scaled by the curve
        let usable = max(0, 100 - context.reservePct)
        let usualPerKm = context.usualPctPerKm ?? fitted.y(base)
        func range(_ v: Double) -> Double {
            let scale = fitted.y(v) / max(1e-6, fitted.y(base))
            return usable / max(1e-6, usualPerKm * scale)
        }
        let gain = range(best) - range(base)
        let gainKm = Int(gain.rounded())

        let to = context.destination.map { " to \($0)" } ?? ""
        func timeDeltaMin(_ v: Double) -> Int? {
            guard let d = context.routeKm, d > 0, v > 0 else { return nil }
            return Int((d * 60 * (1 / v - 1 / base)).rounded())
        }
        var rows: [WhatIfRow] = []
        for step in [-5.0, 0, 5, 10] {
            let v = base + step
            guard v >= minKmh, v >= lo - 3, v <= hi + 3 else { continue }
            if step == 0 {
                var text = "~\(Int(range(base).rounded())) km range"
                if let t = context.routeTimeS { text += " \u{00B7} \(Int((t / 60).rounded())) min" }
                rows.append(WhatIfRow(label: "\(Int(v)) km/h", items: [WhatIfItem(text, .neutral)], isBaseline: true))
                continue
            }
            let dKm = Int((range(v) - range(base)).rounded())
            var items = [WhatIfItem(dKm == 0 ? "same range" : "\(InsightFormat.signedInt(dKm)) km range", dKm > 0 ? .better : (dKm < 0 ? .worse : .neutral))]
            if let dt = timeDeltaMin(v) {
                items.append(WhatIfItem(dt == 0 ? "same time" : "\(InsightFormat.signedInt(dt)) min\(rows.isEmpty ? to : "")",
                                        dt < 0 ? .better : (dt > 0 ? .worse : .neutral)))
            }
            rows.append(WhatIfRow(label: "\(Int(v)) km/h", note: "(\(InsightFormat.signedInt(Int(step))))", items: items))
        }

        // the chart: groups of 2 km/h as dots, the curve with its band, the sweet spot interval highlighted
        var groups: [Int: (w: Double, y: Double, x: Double)] = [:]
        for s in all {
            let key = Int((s.speedKmh / 2).rounded(.down))
            let g = groups[key] ?? (0, 0, 0)
            groups[key] = (g.w + s.km, g.y + s.km * s.whPerKm / context.whPerPct, g.x + s.km * s.speedKmh)
        }
        let dots = groups.keys.sorted().compactMap { k -> InsightDot? in
            guard let g = groups[k], g.w > 0 else { return nil }
            return InsightDot(x: g.x / g.w, y: g.y / g.w)
        }
        var curvePts: [InsightCurvePoint] = []
        var x = lo
        while x <= hi + 1e-9 {
            let y = fitted.y(x), e = tq * fitted.se(x)
            curvePts.append(InsightCurvePoint(x: x, y: y, lo: y - e, hi: y + e))
            x += 0.5
        }
        let xt = InsightFormat.ticks(lo, hi, count: 5)
        let ys = dots.map(\.y) + curvePts.map(\.lo) + curvePts.map(\.hi)
        let yt = InsightFormat.ticks(ys.min() ?? 0, ys.max() ?? 1, count: 3)
        let chart = InsightChart(title: "Your rides, battery per km by speed", dots: dots, curve: curvePts,
                                 band: max(lo, (best - half).rounded(.down))...min(hi, (best + half).rounded(.up)),
                                 xTicks: xt, xLabels: xt.enumerated().map { i, v in "\(Int(v.rounded()))" + (i == xt.count - 1 ? " km/h" : "") },
                                 yTicks: yt, yLabels: yt.map { InsightFormat.one($0) + "%" },
                                 caption: "Dots = your stretches of steady riding \u{00B7} band = how sure we are")

        let totalKm = used.reduce(0.0) { $0 + $1.distanceKm }
        let first = used.map(\.startAt).min() ?? 0, last = used.map(\.startAt).max() ?? 0
        var left = [String]()
        if cuts.climbs > 0 { left.append("\(cuts.climbs) climb\(cuts.climbs == 1 ? "" : "s")") }
        if cuts.windyRides > 0 { left.append("\(cuts.windyRides) windy ride\(cuts.windyRides == 1 ? "" : "s")") }
        let exclusions = "Only steady stretches (\u{2265} 1 min at a constant speed). Climbs, stops and strong wind left out"
            + (left.isEmpty ? "." : " (\(left.joined(separator: ", "))).")

        let lowKmh = Int((best - half).rounded(.down)), highKmh = Int((best + half).rounded(.up))
        let spread = fitted.fit.sigma
        let action: String
        if abs(base - best) >= 2, gainKm >= 1 {
            action = "Cruising at \(bestInt) gives you ~\(gainKm) km more range"
        } else {
            action = "You already cruise close to it (\(Int(base)) km/h)"
        }
        let card = InsightCard(
            topic: .sweetSpot, kind: .pattern,
            headline: "Your sweet spot is \(bestInt) km/h",
            value: InsightFormat.one(yBest), unit: "%",
            context: "per km \u{00B7} vs \(InsightFormat.one(yFast)) % at \(Int(fast))",
            action: action,
            basedOn: "Based on \(rideCount) rides",
            meaning: "Around \(bestInt) km/h each km costs you the least battery. "
                + (best < hi - 3 ? "Faster, the air resistance climbs quickly." : "Slower, the motor works less efficiently."),
            chart: chart,
            whatIfTitle: "What if you cruise\u{2026}",
            whatIf: rows,
            whatIfNote: "Range from a full battery, on your usual routes and load." + (context.routeKm == nil ? "" : " Time if you held that speed the whole way."),
            evidence: InsightEvidence(rides: rideCount, km: totalKm, span: InsightFormat.span(fromMs: first, toMs: last, utcOffsetMin: context.utcOffsetMin),
                                      exclusions: exclusions),
            method: ["battery used \u{00F7} km, grouped by speed", "\u{2192} curve fitted through the groups", "\u{2192} lowest point = sweet spot"],
            certainty: InsightCertainty(level: level, interval: "Sweet spot between \(lowKmh) and \(highKmh) km/h.",
                                        agreement: "Your rides agree within \u{00B1}\(spread < 0.1 ? InsightFormat.two(spread) : InsightFormat.one(spread)) % per km. More rides make it sharper."),
            tryThis: "Cruise at \(bestInt) when range matters. On short trips, ride as you like.",
            weight: max(0, gain))
        return .card(card)
    }
}
