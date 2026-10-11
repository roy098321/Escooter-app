import Foundation

// M6-01 (Q23, INSIGHTS C14b): the fastest combination of the options at a route's choice points, for a ride today.
//
// Model: ride time = rest (the shared stretches) + the option time at every choice point.
// - Option time today = median of its rides' times with each ride's own factor effects taken out (M24 route effects per trip,
//   scaled by the option's share of the route length) + today's factor effects at the same share.
// - Rest = median of (ride total - its option times), factors handled the same way at the rest's share.
// - Gates (S5 / T95): each option needs 3 rides; a choice point with no option at 3 rides stops the answer ("not enough data");
//   the combination must beat the fastest way already ridden as a whole by >= 1 min, decided with the 10% margin (G2: 66 s);
//   the time shown stays honest. Once the fastest combination has been ridden as a whole, it is a normal variant (no card).
// Navigation stays on ridden paths: the combination is the reference with ridden option stretches put in.

/// One ride of the route for the estimate.
public struct CombinationRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var totalS: Double?
    public var excluded: Bool
    /// The ride's factor levels that have route effects: "head" "tail" "rush" "friday" "saturday"
    public var levels: Set<String>

    public init(id: String, startAt: Int64, totalS: Double?, excluded: Bool = false, levels: Set<String> = []) {
        self.id = id
        self.startAt = startAt
        self.totalS = totalS
        self.excluded = excluded
        self.levels = levels
    }
}

public struct CombinationInput: Sendable {
    public var routeId: String
    public var reference: [GeoPoint]
    public var routeLengthM: Double
    public var choices: ChoiceSet
    public var rides: [CombinationRide]
    /// Route time effects per trip that passed their gate (M24), by level ("rush" → +120 s)
    public var tripEffectsS: [String: Double]
    /// Today's levels (forecast headwind, rush hour at the departure, day type)
    public var todayLevels: Set<String>
    public var nowMs: Int64

    public init(routeId: String, reference: [GeoPoint], routeLengthM: Double, choices: ChoiceSet, rides: [CombinationRide],
                tripEffectsS: [String: Double] = [:], todayLevels: Set<String> = [], nowMs: Int64) {
        self.routeId = routeId
        self.reference = reference
        self.routeLengthM = routeLengthM
        self.choices = choices
        self.rides = rides
        self.tripEffectsS = tripEffectsS
        self.todayLevels = todayLevels
        self.nowMs = nowMs
    }
}

public struct OptionEstimate: Equatable, Sendable {
    public var optionId: String
    public var choicePointId: String
    public var name: String
    public var isReference: Bool
    /// Rides through the option (in the window)
    public var rides: Int
    /// Today's time on the option (s); nil under the gate (< 3 rides)
    public var timeS: Double?
    public var lengthM: Double
}

/// The option taken at one choice point (also what M6-02's live prompt needs).
public struct ChosenWay: Equatable, Sendable {
    public var choicePointId: String
    public var optionId: String
    public var name: String
    public var isReference: Bool
    public var split: GeoPoint
    public var rejoin: GeoPoint
    public var posOnRefM: Double
    public var timeS: Double
    /// Seconds this option saves over the next fastest option at 3 rides here (0: no other)
    public var savingS: Double
    /// The next fastest option (nil: no other at 3 rides)
    public var runnerUpId: String?
    /// How far the option gets from the runner-up's path (S2: prompts only >= 30 m)
    public var apartM: Double
    public var basedOnN: Int
}

public struct FastestCombo: Equatable, Sendable {
    public var timeS: Double
    /// The fastest way already ridden as a whole (modelled the same way)
    public var bestRealS: Double
    /// bestRealS - timeS (honest, shown)
    public var savingS: Double
    public var ways: [ChosenWay]
    /// The whole path to follow (reference + the chosen option stretches), every point ridden before
    public var path: [GeoPoint]
    /// The fewest rides behind any part of the estimate
    public var basedOnN: Int
    public var factorsApplied: Bool
}

public enum FastestState: Equatable, Sendable {
    /// No choice points on the route (S9: no section)
    case noChoicePoints
    /// A choice point (or the shared stretches) has no option at 3 rides yet
    case notEnoughData(have: Int, need: Int, name: String)
    /// The fastest combination is a way already ridden as a whole: it is a normal variant
    case alreadyRidden(FastestCombo)
    /// Saves less than the gate over the fastest way already ridden
    case notWorthIt(FastestCombo)
    case combination(FastestCombo)
}

public struct WaitingOption: Equatable, Sendable {
    public var optionId: String
    public var name: String
    public var have: Int
    public var need: Int
}

public struct FastestAnswer: Equatable, Sendable {
    public var state: FastestState
    /// Options seen 1 or 2 times: not used yet (pattern D lines)
    public var waiting: [WaitingOption]
    public var estimates: [OptionEstimate]

    public var combo: FastestCombo? {
        switch state {
        case .combination(let c), .notWorthIt(let c), .alreadyRidden(let c): return c
        default: return nil
        }
    }
}

public enum FastestCombination {
    /// S5 / T95 / T93: rides each option needs
    public static let optionRides = T.t93ShortcutRides
    /// T95: the combination must beat the fastest way already ridden by this much
    public static let beatBestS = 60.0
    /// Options closer than this are a tie: the usual way wins, then the more ridden one
    public static let tieS = 1.0
    /// Rides older than this are left out (a year: the seasons repeat, the streets mostly do not change)
    public static let windowDays = 365.0
    /// Newest rides per option in the median
    public static let newestPerOption = 20

    static func share(_ lengthM: Double, of routeM: Double) -> Double {
        routeM > 0 ? max(0, min(1, lengthM / routeM)) : 0
    }

    static func effect(_ levels: Set<String>, _ effects: [String: Double]) -> Double {
        levels.reduce(0.0) { $0 + (effects[$1] ?? 0) }
    }

    public static func answer(_ input: CombinationInput) -> FastestAnswer {
        let points = input.choices.points.sorted { $0.posOnRefM < $1.posOnRefM }
        guard !points.isEmpty else { return FastestAnswer(state: .noChoicePoints, waiting: [], estimates: []) }
        let windowStart = input.nowMs - Int64(windowDays * 86_400_000)
        var rides: [String: CombinationRide] = [:]
        for r in input.rides where !r.excluded && r.startAt >= windowStart { rides[r.id] = r }
        let routeM = input.routeLengthM > 0 ? input.routeLengthM : Geo.pathLengthM(input.reference)
        let today = effect(input.todayLevels, input.tripEffectsS)
        let costs = input.choices.costs.filter { rides[$0.rideId] != nil }

        // option estimates
        var estimates: [OptionEstimate] = []
        var waiting: [WaitingOption] = []
        var estimateById: [String: OptionEstimate] = [:]
        for p in points {
            for o in p.options {
                let mine = costs.filter { $0.optionId == o.id }.sorted { rides[$0.rideId]!.startAt > rides[$1.rideId]!.startAt }
                let s = share(o.lengthM, of: routeM)
                let normalised = mine.prefix(newestPerOption).map { $0.timeS - effect(rides[$0.rideId]!.levels, input.tripEffectsS) * s }
                var time: Double?
                if mine.count >= optionRides, let m = Geo.median(Array(normalised)) { time = m + today * s }
                let e = OptionEstimate(optionId: o.id, choicePointId: p.id, name: o.name, isReference: o.isReference, rides: mine.count,
                                       timeS: time, lengthM: o.lengthM)
                estimates.append(e)
                estimateById[o.id] = e
                if mine.count > 0 && mine.count < optionRides {
                    waiting.append(WaitingOption(optionId: o.id, name: o.name, have: mine.count, need: optionRides))
                }
            }
        }

        // the rest (shared stretches): rides through every choice point with a total time
        var tuples: [String: [String: String]] = [:]       // ride → choice point → option
        for c in costs { tuples[c.rideId, default: [:]][c.choicePointId] = c.optionId }
        let complete = tuples.filter { $0.value.count == points.count }
        let refOptionM = points.reduce(0.0) { sum, p in sum + (p.options.first { $0.isReference }?.lengthM ?? 0) }
        let restShare = share(max(0, routeM - refOptionM), of: routeM)
        var restValues: [(Int64, Double)] = []
        for (rideId, tuple) in complete {
            guard let r = rides[rideId], let total = r.totalS else { continue }
            let onOptions = costs.filter { $0.rideId == rideId && tuple[$0.choicePointId] == $0.optionId }.reduce(0.0) { $0 + $1.timeS }
            restValues.append((r.startAt, total - onOptions - effect(r.levels, input.tripEffectsS) * restShare))
        }
        restValues.sort { $0.0 > $1.0 }
        let needRest = T.t67EnoughTimeRides
        guard restValues.count >= needRest, let restMedian = Geo.median(restValues.prefix(newestPerOption * 2).map { $0.1 }) else {
            return FastestAnswer(state: .notEnoughData(have: restValues.count, need: needRest, name: "whole rides"), waiting: waiting,
                                 estimates: estimates)
        }
        let rest = restMedian + today * restShare

        // the fastest option at every choice point
        var chosen: [ChosenWay] = []
        for p in points {
            let gated = p.options.compactMap { estimateById[$0.id] }.filter { $0.timeS != nil }
            guard let fastest = pick(gated) else {
                let most = p.options.compactMap { estimateById[$0.id] }.max { $0.rides < $1.rides }
                return FastestAnswer(state: .notEnoughData(have: most?.rides ?? 0, need: optionRides, name: most?.name ?? "usual way"),
                                     waiting: waiting, estimates: estimates)
            }
            let others = gated.filter { $0.optionId != fastest.optionId }
            let runnerUp = pick(others)
            let option = p.options.first(where: { $0.id == fastest.optionId })!
            var apart = 0.0
            if let ru = runnerUp, let other = p.options.first(where: { $0.id == ru.optionId }) { apart = ChoicePointDetector.apartM(option.path, from: other.path) }
            chosen.append(ChosenWay(choicePointId: p.id, optionId: fastest.optionId, name: fastest.name, isReference: fastest.isReference,
                                    split: p.split, rejoin: p.rejoin, posOnRefM: p.posOnRefM, timeS: fastest.timeS!,
                                    savingS: runnerUp.map { $0.timeS! - fastest.timeS! } ?? 0, runnerUpId: runnerUp?.optionId,
                                    apartM: apart, basedOnN: fastest.rides))
        }
        let comboS = rest + chosen.reduce(0.0) { $0 + $1.timeS }
        let comboTuple = Dictionary(uniqueKeysWithValues: chosen.map { ($0.choicePointId, $0.optionId) })

        // the fastest way already ridden as a whole (every option of it at 3 rides)
        var bestReal: Double?
        var riddenTuples: [[String: String]] = []
        for t in complete.values where !riddenTuples.contains(t) { riddenTuples.append(t) }
        for t in riddenTuples {
            var sum = rest
            var ok = true
            for (_, optionId) in t {
                guard let time = estimateById[optionId]?.timeS else { ok = false; break }
                sum += time
            }
            if ok { bestReal = min(bestReal ?? .infinity, sum) }
        }
        let basedOn = min(restValues.count, chosen.map(\.basedOnN).min() ?? restValues.count)
        let combo = FastestCombo(timeS: comboS, bestRealS: bestReal ?? comboS, savingS: (bestReal ?? comboS) - comboS, ways: chosen,
                                 path: path(reference: input.reference, points: points, chosen: chosen), basedOnN: basedOn,
                                 factorsApplied: today != 0)
        if riddenTuples.contains(comboTuple) {
            return FastestAnswer(state: .alreadyRidden(combo), waiting: waiting, estimates: estimates)
        }
        guard bestReal != nil else {
            let weakest = estimates.filter { $0.timeS == nil && $0.rides > 0 }.max { $0.rides < $1.rides }
            return FastestAnswer(state: .notEnoughData(have: weakest?.rides ?? 0, need: optionRides, name: weakest?.name ?? "whole rides"),
                                 waiting: waiting, estimates: estimates)
        }
        // G2: the decision uses the gate + 10% (66 s); the saving shown is the honest one
        if combo.savingS >= SafetyMargin.forDecision(beatBestS) {
            return FastestAnswer(state: .combination(combo), waiting: waiting, estimates: estimates)
        }
        return FastestAnswer(state: .notWorthIt(combo), waiting: waiting, estimates: estimates)
    }

    /// The fastest of the options; within `tieS` the usual way wins, then the more ridden, then the id.
    static func pick(_ options: [OptionEstimate]) -> OptionEstimate? {
        guard let best = options.compactMap(\.timeS).min() else { return nil }
        let tied = options.filter { ($0.timeS ?? .infinity) - best < tieS }
        return tied.sorted { a, b in
            if a.isReference != b.isReference { return a.isReference }
            if a.rides != b.rides { return a.rides > b.rides }
            return a.optionId < b.optionId
        }.first
    }

    /// The reference with the chosen option stretches put in (all of it ridden before).
    public static func path(reference: [GeoPoint], points: [ChoicePoint], chosen: [ChosenWay]) -> [GeoPoint] {
        let ref = Geo.resample(reference, stepM: TripBuilder.pathStepM)
        guard ref.count >= 2 else { return reference }
        let cum = ChoicePointDetector.cumulative(ref)
        var out: [GeoPoint] = []
        var at = 0.0
        for p in points.sorted(by: { $0.posOnRefM < $1.posOnRefM }) {
            guard let way = chosen.first(where: { $0.choicePointId == p.id }), !way.isReference,
                  let option = p.options.first(where: { $0.id == way.optionId }) else { continue }
            out += ChoicePointDetector.slice(ref, cum: cum, from: at, to: p.posOnRefM)
            out += option.path
            at = p.rejoinOnRefM
        }
        out += ChoicePointDetector.slice(ref, cum: cum, from: at, to: cum[cum.count - 1])
        return out
    }
}

/// The route card section (Variants → Fastest combination); all text here so the screen only draws it.
public struct FastestCard: Equatable, Sendable {
    /// "Fastest combination ~13:10"
    public var headline: String
    /// "park shortcut + left at the lights · never ridden as a whole"
    public var detail: String
    /// "About 1:30 faster than your fastest way so far · based on 3+ rides on each way"
    public var note: String?
    /// Options still learning: "way 2 at km 1.4: 1 of 3 rides"
    public var waiting: [String]
    /// "Follow this next ride" is offered
    public var canFollow: Bool
    /// The path the Follow button highlights
    public var path: [GeoPoint]
    /// Pattern D (filling up)
    public var filling: Bool
    /// What the combination's time is for Follow (the honest estimate)
    public var timeS: Double?

    public static func clock(_ s: Double) -> String {
        let total = Int(abs(s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// nil = no choice points (S9: no section)
    public static func make(_ answer: FastestAnswer) -> FastestCard? {
        let waiting = answer.waiting.map { "\($0.name): \($0.have) of \($0.need) rides" }
        switch answer.state {
        case .noChoicePoints:
            return nil
        case .notEnoughData(let have, let need, let name):
            return FastestCard(headline: "Fastest combination: not enough data yet",
                               detail: "Each way needs \(need) rides \u{00B7} \(name): \(min(have, need)) of \(need)",
                               note: nil, waiting: waiting, canFollow: false, path: [], filling: true, timeS: nil)
        case .alreadyRidden(let c):
            let names = c.ways.filter { !$0.isReference }.map(\.name)
            let detail = names.isEmpty ? "Your usual way is the fastest so far" : names.joined(separator: " + ")
            return FastestCard(headline: "Fastest combination ~\(clock(c.timeS))", detail: detail + " \u{00B7} you already ride it",
                               note: InsightText.basedOn(c.basedOnN), waiting: waiting, canFollow: false, path: c.path, filling: false,
                               timeS: c.timeS)
        case .notWorthIt(let c):
            return FastestCard(headline: "Fastest combination: no faster mix yet",
                               detail: "The fastest mix saves under 1 min over your fastest way so far",
                               note: InsightText.basedOn(c.basedOnN), waiting: waiting, canFollow: false, path: [], filling: false, timeS: nil)
        case .combination(let c):
            let names = c.ways.filter { !$0.isReference }.map(\.name)
            var note = "About \(clock(c.savingS)) faster than your fastest way so far \u{00B7} at least \(c.basedOnN) rides on each part"
            if c.factorsApplied { note += " \u{00B7} today's conditions included" }
            return FastestCard(headline: "Fastest combination ~\(clock(c.timeS))",
                               detail: names.joined(separator: " + ") + " \u{00B7} never ridden as a whole",
                               note: note, waiting: waiting, canFollow: true, path: c.path, filling: false, timeS: c.timeS)
        }
    }
}
