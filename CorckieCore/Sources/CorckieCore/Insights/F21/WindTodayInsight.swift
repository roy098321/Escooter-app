import Foundation

/// One past ride with its headwind and battery use
public struct WindRide: Equatable, Sendable {
    public var startAt: Int64
    public var headwindKmh: Double
    public var pctPerKm: Double
    public var distanceKm: Double

    public init(startAt: Int64, headwindKmh: Double, pctPerKm: Double, distanceKm: Double) {
        self.startAt = startAt
        self.headwindKmh = headwindKmh
        self.pctPerKm = pctPerKm
        self.distanceKm = distanceKm
    }
}

/// Today's likely ride and its forecast
public struct WindToday: Equatable, Sendable {
    /// "Work → Home"
    public var routeTitle: String
    /// "Work" (for "Leave Work with at least …"), nil = unknown
    public var fromName: String?
    /// "Home"
    public var toName: String?
    /// forecast headwind component along the route, km/h (negative = tailwind)
    public var headwindKmh: Double
    public var windKmh: Double
    public var windFromDeg: Double?
    /// local minutes after midnight of the likely departure
    public var departureMinute: Double
    public var routeKm: Double
    /// the honest usual battery % the trip takes
    public var usualUsedPct: Double
    public var reservePct: Double

    public init(routeTitle: String, fromName: String?, toName: String?, headwindKmh: Double, windKmh: Double, windFromDeg: Double?,
                departureMinute: Double, routeKm: Double, usualUsedPct: Double, reservePct: Double) {
        self.routeTitle = routeTitle
        self.fromName = fromName
        self.toName = toName
        self.headwindKmh = headwindKmh
        self.windKmh = windKmh
        self.windFromDeg = windFromDeg
        self.departureMinute = departureMinute
        self.routeKm = routeKm
        self.usualUsedPct = usualUsedPct
        self.reservePct = reservePct
    }
}

/// F-21 today's wind (TODAY, Home only): battery % per km against headwind over your rides (a straight line), times today's forecast
/// headwind and the trip's km = the extra battery. Shown only when it matters (headwind ≥ 15 km/h and ≥ 3 % extra) and the slope is
/// clear. The "Leave with at least N %" is acted on, so N carries the 10 % safety margin and the reserve (P-1); the shown +% is honest.
public enum WindTodayInsight {
    public static let mattersHeadwindKmh = T.t94HeadwindKmh
    public static let mattersExtraPct = 3.0

    /// "north-west" for the direction the wind comes from
    public static func compass(_ deg: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let i = Int(((deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[i]
    }

    /// The battery % to leave with: reserve + (usual + extra) with the 10 % margin, rounded up to 5
    public static func leaveWith(usualPct: Double, extraPct: Double, reservePct: Double) -> Int {
        let need = reservePct + SafetyMargin.forDecision(max(0, usualPct + extraPct))
        return min(100, Int((need / 5).rounded(.up)) * 5)
    }

    public static func make(history: [WindRide], today: WindToday, utcOffsetMin: Int) -> InsightOutcome {
        guard history.count >= InsightGate.windMediumRides else {
            return .learning(.wind, "\(history.count) of \(InsightGate.windMediumRides) rides with wind data")
        }
        guard let fit = InsightMath.leastSquares(rows: history.map { [1, $0.headwindKmh] }, y: history.map(\.pctPerKm)) else {
            return .learning(.wind, "wind has not varied enough yet")
        }
        let slope = fit.beta[1]
        let level = InsightGate.wind(rides: history.count, slopeT: fit.t(1))
        let hw = today.headwindKmh
        let extra = slope * hw * today.routeKm
        guard hw >= mattersHeadwindKmh, extra >= mattersExtraPct else {
            return .learning(.wind, "no headwind that matters today")
        }
        let tq = InsightMath.tCrit(fit.dof)
        let extraLo = max(0, (slope - tq * fit.se(1)) * hw * today.routeKm), extraHi = (slope + tq * fit.se(1)) * hw * today.routeKm
        let n = leaveWith(usualPct: today.usualUsedPct, extraPct: extra, reservePct: today.reservePct)
        let extraInt = Int(extra.rounded())
        let strong = hw >= T.t70WindStrongKmh
        let way: String
        if let to = today.toName {
            way = to.lowercased() == "home" ? "the way home" : "the way to \(to)"
        } else {
            way = "your ride"
        }
        let leave = today.fromName.map { "Leave \($0) with at least \(n) %" } ?? "Leave with at least \(n) %"
        let from = today.windFromDeg.map { " from the \(compass($0))" } ?? ""
        let clock = InsightFormat.clock(today.departureMinute)

        // the chart: your rides by headwind, the fitted line and its band, today's headwind highlighted
        let dots = history.map { InsightDot(x: $0.headwindKmh, y: $0.pctPerKm) }
        let xs = history.map(\.headwindKmh) + [hw]
        let lo = min(0, xs.min() ?? 0), hi = max(hw, xs.max() ?? hw)
        var curve: [InsightCurvePoint] = []
        var x = lo
        while x <= hi + 1e-9 {
            let y = fit.predict([1, x]), e = tq * fit.predictSE([1, x])
            curve.append(InsightCurvePoint(x: x, y: y, lo: y - e, hi: y + e))
            x += max(1, (hi - lo) / 30)
        }
        let xt = InsightFormat.ticks(lo, hi, count: 4)
        let ys = dots.map(\.y) + curve.map(\.lo) + curve.map(\.hi)
        let yt = InsightFormat.ticks(ys.min() ?? 0, ys.max() ?? 1, count: 3)
        let chart = InsightChart(title: "Your rides, battery per km by headwind", dots: dots, curve: curve, band: max(lo, hw - 1.5)...min(hi + 1.5, hw + 1.5),
                                 xTicks: xt, xLabels: xt.enumerated().map { i, v in "\(Int(v.rounded()))" + (i == xt.count - 1 ? " km/h" : "") },
                                 yTicks: yt, yLabels: yt.map { InsightFormat.one($0) + "%" },
                                 caption: "Dots = your rides \u{00B7} band = how sure we are \u{00B7} shaded = today's headwind")
        let usual = Int(today.usualUsedPct.rounded())
        let rows = [
            WhatIfRow(label: "No wind", items: [WhatIfItem("~\(usual) % used", .neutral)], isBaseline: true),
            WhatIfRow(label: "Today", note: "(\(Int(hw.rounded())) km/h against)", items: [WhatIfItem("+\(extraInt) % \u{00B7} ~\(usual + extraInt) % used", .worse)]),
            WhatIfRow(label: "Leave with", note: "(reserve + 10 % margin)", items: [WhatIfItem("at least \(n) %", .neutral)]),
        ]
        let first = history.map(\.startAt).min() ?? 0, last = history.map(\.startAt).max() ?? 0
        let card = InsightCard(
            topic: .wind, kind: .today,
            headline: "\(strong ? "Strong headwind" : "Headwind") on \(way)",
            value: "+\(extraInt)", unit: "%", context: "battery for \(today.routeTitle)",
            action: leave,
            basedOn: "Wind \(Int(today.windKmh.rounded())) km/h\(from) \u{00B7} \(clock)",
            meaning: "The forecast has about \(Int(hw.rounded())) km/h of wind against you on \(today.routeTitle) around \(clock). "
                + "On your rides, wind like that costs about \(extraInt) % more battery for this trip.",
            chart: chart,
            whatIfTitle: "For this trip\u{2026}",
            whatIf: rows,
            whatIfNote: "The % to leave with adds your reserve and a 10 % safety margin; the other numbers are the honest estimate.",
            evidence: InsightEvidence(rides: history.count, km: history.reduce(0.0) { $0 + $1.distanceKm },
                                      span: InsightFormat.span(fromMs: first, toMs: last, utcOffsetMin: utcOffsetMin),
                                      exclusions: "Rides without wind data or a battery reading left out."),
            method: ["battery % \u{00F7} km per ride, against its headwind", "\u{2192} straight line fitted through your rides",
                     "\u{2192} today's headwind \u{00D7} slope \u{00D7} trip km = extra"],
            certainty: InsightCertainty(level: level, interval: "Between +\(Int(extraLo.rounded())) and +\(Int(extraHi.rounded())) % for this trip.",
                                        agreement: "Your rides agree within \u{00B1}\(InsightFormat.one(fit.sigma)) % per km. More windy rides make it sharper."),
            tryThis: "Charge to at least \(n) % before you leave. Riding a little slower into the wind also helps.",
            weight: extra)
        return .card(card)
    }
}
