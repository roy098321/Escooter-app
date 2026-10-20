import Foundation

/// One ride as the creep insight needs it (a saved route, a battery reading, 1 km or more)
public struct CreepRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var routeId: String
    public var pctPerKm: Double
    /// moving average speed, km/h
    public var speedKmh: Double
    public var headwindKmh: Double?
    public var distanceKm: Double

    public init(id: String, startAt: Int64, routeId: String, pctPerKm: Double, speedKmh: Double, headwindKmh: Double?, distanceKm: Double) {
        self.id = id
        self.startAt = startAt
        self.routeId = routeId
        self.pctPerKm = pctPerKm
        self.speedKmh = speedKmh
        self.headwindKmh = headwindKmh
        self.distanceKm = distanceKm
    }
}

/// F-21 battery-use creep (MAINTENANCE): the last 10 rides' battery % per km against a reference period on the same routes, after
/// allowing for speed and wind (a linear fit on the reference rides). An increase of 5 % or more that is clear (t ≥ 2) points at the
/// tyres first.
public enum CreepInsight {
    public static let recentCount = 10
    public static let referenceMax = 30

    public static func make(rides input: [CreepRide], reservePct: Double, utcOffsetMin: Int) -> InsightOutcome {
        let sorted = input.sorted { $0.startAt > $1.startAt }
        let recent = Array(sorted.prefix(recentCount))
        guard recent.count >= InsightGate.creepMediumRides, let recentStart = recent.map(\.startAt).min() else {
            return .learning(.creep, "\(recent.count) of \(InsightGate.creepMediumRides) recent rides")
        }
        let routes = Set(recent.map(\.routeId))
        let reference = Array(sorted.filter { $0.startAt < recentStart && routes.contains($0.routeId) }.prefix(referenceMax))
        let sameRoute = recent.filter { r in reference.contains { $0.routeId == r.routeId } }
        guard reference.count >= InsightGate.creepMediumRides, sameRoute.count >= InsightGate.creepMediumRides else {
            return .learning(.creep, "\(reference.count) of \(InsightGate.creepMediumRides) earlier rides on the same routes")
        }
        // normalise for speed and wind: fit on the reference rides (a column with no spread is left out)
        let s0 = InsightMath.mean(reference.map(\.speedKmh)) ?? 0
        let useSpeed = (InsightMath.variance(reference.map(\.speedKmh)) ?? 0) > 1
        let useWind = (InsightMath.variance(reference.map { $0.headwindKmh ?? 0 }) ?? 0) > 1
        func row(_ r: CreepRide) -> [Double] {
            var v: [Double] = [1]
            if useSpeed { v.append(r.speedKmh - s0) }
            if useWind { v.append(r.headwindKmh ?? 0) }
            return v
        }
        guard let fit = InsightMath.leastSquares(rows: reference.map(row), y: reference.map(\.pctPerKm)) else {
            return .learning(.creep, "the earlier rides do not fit yet")
        }
        let refMean = fit.beta[0]
        guard refMean > 0 else { return .learning(.creep, "no battery use yet") }
        let res = sameRoute.map { $0.pctPerKm - fit.predict(row($0)) }
        let meanRes = InsightMath.mean(res) ?? 0
        let se = fit.sigma * sqrt(1 / Double(sameRoute.count) + 1 / Double(reference.count))
        let t = se > 0 ? meanRes / se : 0
        let share = meanRes / refMean
        let level = InsightGate.creep(recentN: sameRoute.count, referenceN: reference.count, share: share, t: t)

        let refMid = InsightMath.median(reference.map { Double($0.startAt) }).map { Int64($0) } ?? recentStart
        let month = InsightFormat.month(refMid, utcOffsetMin: utcOffsetMin)
        let pct = Int((share * 100).rounded())
        let tq = InsightMath.tCrit(fit.dof)
        let lo = Int(((meanRes - tq * se) / refMean * 100).rounded()), hi = Int(((meanRes + tq * se) / refMean * 100).rounded())

        // the chart: every ride adjusted to the reference speed and wind, the two periods as levels with their bands
        let first = reference.map(\.startAt).min() ?? recentStart
        let last = sameRoute.map(\.startAt).max() ?? recentStart
        func day(_ ms: Int64) -> Double { Double(ms - first) / 86_400_000 }
        func adjusted(_ r: CreepRide) -> Double { r.pctPerKm - (fit.predict(row(r)) - refMean) }
        let dots = (reference + sameRoute).map { InsightDot(x: day($0.startAt), y: adjusted($0)) }
        let refHalf = tq * fit.sigma / sqrt(Double(reference.count))
        let recHalf = tq * fit.sigma / sqrt(Double(sameRoute.count))
        let refEnd = day(reference.map(\.startAt).max() ?? first)
        let recLo = day(sameRoute.map(\.startAt).min() ?? recentStart), recHi = day(last)
        let recentLevel = refMean + meanRes
        let curve = [InsightCurvePoint(x: 0, y: refMean, lo: refMean - refHalf, hi: refMean + refHalf, segment: 0),
                     InsightCurvePoint(x: max(refEnd, 0.5), y: refMean, lo: refMean - refHalf, hi: refMean + refHalf, segment: 0),
                     InsightCurvePoint(x: recLo, y: recentLevel, lo: recentLevel - recHalf, hi: recentLevel + recHalf, segment: 1),
                     InsightCurvePoint(x: max(recHi, recLo + 0.5), y: recentLevel, lo: recentLevel - recHalf, hi: recentLevel + recHalf, segment: 1)]
        let span = max(1, day(last))
        let xt = [0, span / 2, span]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        df.dateFormat = "MMM d"
        let xl = xt.map { df.string(from: Date(timeIntervalSince1970: (Double(first) + $0 * 86_400_000) / 1000)) }
        let ys = dots.map(\.y) + curve.map(\.lo) + curve.map(\.hi)
        let yt = InsightFormat.ticks(ys.min() ?? 0, ys.max() ?? 1, count: 3)
        let chart = InsightChart(title: "Your rides, battery per km over time", dots: dots, curve: curve,
                                 band: recLo...max(recHi, recLo + 0.5), xTicks: xt, xLabels: xl, yTicks: yt, yLabels: yt.map { InsightFormat.one($0) + "%" },
                                 caption: "Dots = your rides, at the same speed and wind \u{00B7} lines = \(month) and now")

        // what if: range from full now, back to the reference, another 5 % worse (honest, no margin)
        let usable = max(0, 100 - reservePct)
        let nowRange = usable / max(1e-6, recentLevel)
        let backRange = usable / refMean
        let worseRange = usable / max(1e-6, recentLevel * 1.05)
        let dBack = Int((backRange - nowRange).rounded()), dWorse = Int((worseRange - nowRange).rounded())
        let rows = [
            WhatIfRow(label: "As it is now", items: [WhatIfItem("~\(Int(nowRange.rounded())) km range", .neutral)], isBaseline: true),
            WhatIfRow(label: "Back to \(month)", note: "(tyres pumped)", items: [WhatIfItem("\(InsightFormat.signedInt(dBack)) km range", dBack > 0 ? .better : .neutral)]),
            WhatIfRow(label: "Another 5 % worse", items: [WhatIfItem("\(InsightFormat.signedInt(dWorse)) km range", dWorse < 0 ? .worse : .neutral)]),
        ]
        let all = reference + sameRoute
        let shortMonth = String(month.prefix(3))
        let card = InsightCard(
            topic: .creep, kind: .maintenance,
            headline: "Using more battery than in \(month)",
            value: "+\(pct)", unit: "%", context: "per km, same routes",
            action: "Check tyre pressure (usually the cause)",
            basedOn: "Last \(sameRoute.count) rides vs \(shortMonth) \u{00B7} same speed and wind",
            meaning: "Your last \(sameRoute.count) rides used about \(pct) % more battery per km than in \(month), on the same routes, after allowing for "
                + "speed and wind. Soft tyres are the usual cause; a rubbing brake or extra load are the others.",
            chart: chart,
            whatIfTitle: "What it does to your range\u{2026}",
            whatIf: rows,
            whatIfNote: "Range from a full battery, on your usual routes and load.",
            evidence: InsightEvidence(rides: all.count, km: all.reduce(0.0) { $0 + $1.distanceKm },
                                      span: InsightFormat.span(fromMs: first, toMs: last, utcOffsetMin: utcOffsetMin),
                                      exclusions: "Only routes you rode in both periods. Short rides and rides without a battery reading left out."),
            method: ["battery % \u{00F7} km, per ride", "\u{2192} adjusted for speed and wind (fitted on \(month))", "\u{2192} last \(sameRoute.count) rides vs \(month)"],
            certainty: InsightCertainty(level: level, interval: "Between \(InsightFormat.signedInt(lo)) and \(InsightFormat.signedInt(hi)) % per km.",
                                        agreement: "Rides agree within \u{00B1}\(InsightFormat.one(fit.sigma)) % per km. More rides make it sharper."),
            tryThis: "Pump the tyres to the pressure on the tyre wall, then ride as usual. If the next rides drop back, that was it.",
            weight: share * 100)
        return .card(card)
    }
}
