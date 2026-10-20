import Foundation

/// One ride of the usual route as the departure insight needs it
public struct DepartureRide: Equatable, Sendable {
    public var startAt: Int64
    public var utcOffsetMin: Int
    public var totalS: Double
    public var distanceKm: Double

    public init(startAt: Int64, utcOffsetMin: Int, totalS: Double, distanceKm: Double) {
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.totalS = totalS
        self.distanceKm = distanceKm
    }

    /// local minutes after midnight
    public var minuteOfDay: Double {
        let m = (startAt / 60_000 + Int64(utcOffsetMin)) % 1440
        return Double(m < 0 ? m + 1440 : m)
    }
}

/// F-21 departure time (PATTERN): on the most common route, ride time by the 20-minute window you left in; the quickest window with
/// enough rides against your usual one (Welch), and what leaving 15 / 30 min earlier or later does (a kernel mean of your own rides).
public enum DepartureInsight {
    public static let windowMin = 20.0
    public static let minRides = 6
    /// windows further than this from the usual time are not a realistic change
    public static let maxShiftMin = 90.0
    /// a ride slower than 1.6 × the median had a long stop or a detour: left out
    public static let slowShare = 1.6
    public static let kernelMin = 15.0

    static func roundTo5(_ m: Double, up: Bool = false) -> Double {
        up ? (m / 5).rounded(.up) * 5 : (m / 5).rounded() * 5
    }

    public static func make(rides input: [DepartureRide], destination: String?, utcOffsetMin: Int) -> InsightOutcome {
        guard let med = InsightMath.median(input.map(\.totalS)), med > 0 else {
            return .learning(.departure, "0 of \(minRides) rides on your usual route")
        }
        let rides = input.filter { $0.totalS <= slowShare * med }
        let slowCut = input.count - rides.count
        guard rides.count >= minRides else {
            return .learning(.departure, "\(rides.count) of \(minRides) rides on your usual route")
        }
        var windows: [Int: [DepartureRide]] = [:]
        for r in rides { windows[Int(r.minuteOfDay / windowMin), default: []].append(r) }
        guard let habitKey = windows.keys.max(by: { a, b in
            let ca = windows[a]?.count ?? 0, cb = windows[b]?.count ?? 0
            return ca == cb ? a > b : ca < cb
        }), let habit = windows[habitKey] else {
            return .learning(.departure, "no usual time yet")
        }
        let habitMinute = InsightMath.median(habit.map(\.minuteOfDay)) ?? Double(habitKey) * windowMin
        let habitMean = InsightMath.mean(habit.map(\.totalS)) ?? med
        var bestKey: Int?
        var bestMean = habitMean
        for (k, list) in windows where k != habitKey && list.count >= InsightGate.departMediumPerWindow {
            let m = InsightMath.mean(list.map(\.totalS)) ?? .infinity
            let shift = abs(Double(k - habitKey)) * windowMin
            if shift <= maxShiftMin, m < bestMean {
                bestMean = m
                bestKey = k
            }
        }
        guard let bk = bestKey, let best = windows[bk],
              let d = InsightMath.meanDifference(habit.map(\.totalS), best.map(\.totalS)) else {
            return .learning(.departure, "your usual time is the quickest so far")
        }
        let gain = d.diff
        let t = d.se > 0 ? d.diff / d.se : 0
        let level = InsightGate.departure(bestN: best.count, habitN: habit.count, gainS: gain, t: t)
        let bestMinute = InsightMath.median(best.map(\.minuteOfDay)) ?? Double(bk) * windowMin
        let earlier = bestMinute < habitMinute
        let gainMin = max(1, Int((gain / 60).rounded()))
        let toText = destination.map { "to \($0)" } ?? "on your usual route"
        let bestShown = roundTo5(bestMinute), habitShown = roundTo5(habitMinute)
        let action = earlier ? "Try leaving by \(InsightFormat.clock(roundTo5(bestMinute, up: true)))"
            : "Try leaving around \(InsightFormat.clock(bestShown))"

        // what if: the kernel mean of your rides at the usual time ± 15 / 30 min
        let xs = rides.map(\.minuteOfDay), ys = rides.map(\.totalS)
        let atHabit = InsightMath.kernelMean(xs: xs, ys: ys, at: habitMinute, bw: kernelMin)
        var rows: [WhatIfRow] = []
        for off in [-30.0, -15, 0, 15, 30] {
            let at = habitMinute + off
            guard let k = InsightMath.kernelMean(xs: xs, ys: ys, at: at, bw: kernelMin), k.nEff >= 2, let base = atHabit else { continue }
            if off == 0 {
                rows.append(WhatIfRow(label: "Leave \(InsightFormat.clock(habitShown))", items: [WhatIfItem("~\(Int((base.mean / 60).rounded())) min", .neutral)],
                                      isBaseline: true))
                continue
            }
            let dm = Int(((k.mean - base.mean) / 60).rounded())
            rows.append(WhatIfRow(label: "Leave \(InsightFormat.clock(roundTo5(at)))", note: "(\(InsightFormat.signedInt(Int(off))) min)",
                                  items: [WhatIfItem(dm == 0 ? "same time" : "\(InsightFormat.signedInt(dm)) min", dm < 0 ? .better : (dm > 0 ? .worse : .neutral))]))
        }

        // the chart: each ride a dot, the kernel curve with its band, the quickest window highlighted
        let tq = InsightMath.tCrit(d.dof)
        let lo = (xs.min() ?? 0), hi = (xs.max() ?? 1440)
        var curve: [InsightCurvePoint] = []
        var x = lo
        while x <= hi + 1e-9 {
            if let k = InsightMath.kernelMean(xs: xs, ys: ys, at: x, bw: kernelMin), k.nEff >= 2, k.se.isFinite {
                curve.append(InsightCurvePoint(x: x, y: k.mean / 60, lo: (k.mean - tq * k.se) / 60, hi: (k.mean + tq * k.se) / 60))
            }
            x += 5
        }
        let dots = rides.map { InsightDot(x: $0.minuteOfDay, y: $0.totalS / 60) }
        let xt = InsightFormat.ticks(lo, hi, count: 4).map { ($0 / 15).rounded() * 15 }
        let allY = dots.map(\.y) + curve.map(\.lo) + curve.map(\.hi)
        let yt = InsightFormat.ticks(allY.min() ?? 0, allY.max() ?? 1, count: 3)
        let bandLo = Double(bk) * windowMin
        let bLo = max(lo, bandLo), bHi = min(hi, bandLo + windowMin)
        let chart = InsightChart(title: "Your rides, ride time by when you left", dots: dots, curve: curve,
                                 band: bHi > bLo ? bLo...bHi : nil,
                                 xTicks: Array(Set(xt)).sorted(), xLabels: Array(Set(xt)).sorted().map { InsightFormat.clock($0) },
                                 yTicks: yt, yLabels: yt.map { "\(Int($0.rounded())) min" },
                                 caption: "Dots = your rides \u{00B7} band = how sure we are \u{00B7} shaded = quickest window")

        let lowMin = Int(max(0, (gain - tq * d.se) / 60).rounded()), highMin = Int(((gain + tq * d.se) / 60).rounded())
        let interval = lowMin >= 1 ? "Leaving then saves between \(lowMin) and \(highMin) min." : "Leaving then saves up to \(highMin) min."
        let varHabit: Double = InsightMath.variance(habit.map(\.totalS)) ?? 0
        let varBest: Double = InsightMath.variance(best.map(\.totalS)) ?? 0
        let spread = sqrt((varHabit + varBest) / 2) / 60
        let first = rides.map(\.startAt).min() ?? 0, last = rides.map(\.startAt).max() ?? 0
        let card = InsightCard(
            topic: .departure, kind: .pattern,
            headline: "Leaving at \(InsightFormat.clock(bestShown)) beats \(InsightFormat.clock(habitShown))",
            value: InsightFormat.minus + "\(gainMin)", unit: "min", context: toText,
            action: action,
            basedOn: "Based on \(rides.count) rides",
            meaning: "On your usual route, rides that left around \(InsightFormat.clock(bestShown)) took about \(gainMin) min less than the ones at "
                + "\(InsightFormat.clock(habitShown)), your usual time. Traffic and lights, most likely.",
            chart: chart,
            whatIfTitle: "What if you leave\u{2026}",
            whatIf: rows,
            whatIfNote: "Ride time from your own rides that left around then. A row is missing when there are too few.",
            evidence: InsightEvidence(rides: rides.count, km: rides.reduce(0.0) { $0 + $1.distanceKm },
                                      span: InsightFormat.span(fromMs: first, toMs: last, utcOffsetMin: utcOffsetMin),
                                      exclusions: "Only this route, in this direction. Rides with a long stop or a detour left out"
                                        + (slowCut > 0 ? " (\(slowCut))." : ".")),
            method: ["ride time, grouped by when you left (20 min)", "\u{2192} quickest group vs your usual group", "\u{2192} difference = time saved"],
            certainty: InsightCertainty(level: level, interval: interval,
                                        agreement: "Rides in each group agree within \u{00B1}\(max(1, Int(spread.rounded()))) min. More rides make it sharper."),
            tryThis: "\(action) for a week and see. Same ride, less time in traffic.",
            weight: gain / 60)
        return .card(card)
    }
}
