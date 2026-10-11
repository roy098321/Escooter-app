import Foundation

// M6-02 (Q23 live, T95 / S1 / S2 / S3 / S4): live prompts at the choice points of the combination being followed.
//
// - One prompt at a time, for the next choice point ahead whose chosen way saves >= 20 s over the runner-up (decision with the
//   10% margin) and whose options are >= 30 m apart. It shows when the split is <= 15 s ahead at the current speed (at least
//   3 m/s, so a slow start still gets ~45 m) and is gone 30 m past the split.
// - Text: "Keep left · Way via Park Ave · saves ~1:40" (turn words only when the way bends > 30 degrees away from the road before),
//   "Stay on the usual way · saves ~40 s" where the usual way is the fastest.
// - S3: when the rider takes another ridden option of the choice point, nothing is said: the path is re-planned quietly (the
//   chosen stretch is replaced by the option ridden, the rest of the combination stays) and the point is done.
// - Visual only (pocket riding, P6 2b): nothing is lost when a prompt is not seen.

public struct ChoicePrompt: Equatable, Sendable {
    public var id: String
    public var text: String
}

public struct ChoicePromptUpdate: Equatable, Sendable {
    public var prompt: ChoicePrompt?
    /// The rider took another ridden way: the new path to follow (the follower is rebuilt on it)
    public var newPath: [GeoPoint]?
}

public struct ChoicePrompter: Equatable, Sendable {
    /// T95: the prompt shows this long before the split
    public static let aheadS = 15.0
    /// S1: the chosen way must save at least this much (decided with the 10% margin)
    public static let minSavingS = 20.0
    /// S2: the options must be at least this far apart
    public static let minApartM = 30.0
    /// The prompt is gone this far past the split
    public static let passedM = 30.0
    /// Speed used when slower (m/s)
    public static let minSpeedMps = 3.0
    /// A fix this close to another option, and this far from the chosen one, means the other way was taken
    public static let onOtherM = 15.0
    public static let offChosenM = 30.0

    struct Stop: Equatable, Sendable {
        var way: ChosenWay
        var splitAlong: Double
        var rejoinAlong: Double
        var text: String
        var eligible: Bool
    }

    public private(set) var path: [GeoPoint]
    private var cum: [Double]
    private let points: [ChoicePoint]
    private var ways: [ChosenWay]
    private var stops: [Stop] = []
    private var promptDone: Set<String> = []
    private var done: Set<String> = []
    private var activeId: String?
    private var counted: Set<String> = []
    /// Prompts that came on screen this ride (the ride's developer line, P6)
    public private(set) var shown = 0
    /// Quiet re-plans this ride
    public private(set) var replans = 0

    public init(ways: [ChosenWay], points: [ChoicePoint], path: [GeoPoint]) {
        self.ways = ways.sorted { $0.posOnRefM < $1.posOnRefM }
        self.points = points
        self.path = path
        self.cum = ChoicePointDetector.cumulative(path)
        rebuildStops()
    }

    public init?(combo: FastestCombo, points: [ChoicePoint]) {
        guard combo.path.count >= 2, !combo.ways.isEmpty else { return nil }
        self.init(ways: combo.ways, points: points, path: combo.path)
    }

    /// Choice points the prompter still waits for or watches
    public var pendingCount: Int { stops.filter { !done.contains($0.way.choicePointId) }.count }

    // MARK: Stops

    mutating func rebuildStops() {
        var out: [Stop] = []
        var from = 0.0
        for w in ways {
            let s = ChoicePointDetector.project(w.split, on: path, cum: cum)
            guard s.distanceM < 40 else { continue }
            var rejoin = ChoicePointDetector.project(w.rejoin, on: path, cum: cum).posM
            if rejoin <= s.posM { rejoin = s.posM + 50 }
            let along = max(s.posM, from)
            from = along
            let eligible = w.savingS >= SafetyMargin.forDecision(Self.minSavingS) && w.apartM >= Self.minApartM
            out.append(Stop(way: w, splitAlong: along, rejoinAlong: rejoin, text: Self.text(w, path: path, cum: cum, splitAlong: along),
                            eligible: eligible))
        }
        stops = out
    }

    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dy = b.lat - a.lat
        let dx = (b.lon - a.lon) * cos(a.lat * Double.pi / 180)
        return atan2(dx, dy) * 180 / Double.pi
    }

    /// Turn in degrees at the split: > 0 right, < 0 left (road 30 m before vs the way's first 50 m)
    static func turnDeg(path: [GeoPoint], cum: [Double], at split: Double) -> Double {
        let a = ChoicePointDetector.point(on: path, cum: cum, at: max(0, split - 30))
        let b = ChoicePointDetector.point(on: path, cum: cum, at: split)
        let c = ChoicePointDetector.point(on: path, cum: cum, at: split + 50)
        guard Geo.distanceM(a, b) > 5, Geo.distanceM(b, c) > 5 else { return 0 }
        var d = bearing(b, c) - bearing(a, b)
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    static func text(_ w: ChosenWay, path: [GeoPoint], cum: [Double], splitAlong: Double) -> String {
        let saves = "saves ~\(InsightText.duration(w.savingS))"
        if w.isReference { return "Stay on the usual way \u{00B7} \(saves)" }
        var name = w.name
        if name.hasPrefix("via ") { name = "Way " + name } else if let f = name.first { name = f.uppercased() + name.dropFirst() }
        let turn = turnDeg(path: path, cum: cum, at: splitAlong)
        let word = turn > 30 ? "Keep right \u{00B7} " : (turn < -30 ? "Keep left \u{00B7} " : "")
        return "\(word)\(name) \u{00B7} \(saves)"
    }

    // MARK: Per update (about once a second)

    /// - alongM: where the follower puts the rider on the current path (`path` here is the same path)
    public mutating func update(position: GeoPoint?, gpsFresh: Bool, alongM: Double, offPath: Bool, speedMps: Double) -> ChoicePromptUpdate {
        // S3: the other way taken
        if gpsFresh, let pos = position {
            for s in stops where !done.contains(s.way.choicePointId) && s.splitAlong - alongM < 5 {
                guard alongM <= s.rejoinAlong + 60, let cp = points.first(where: { $0.id == s.way.choicePointId }) else { continue }
                let chosenPath = ChoicePointDetector.slice(path, cum: cum, from: s.splitAlong, to: s.rejoinAlong)
                let dChosen = chosenPath.isEmpty ? Double.infinity : Geo.distanceToPathM(pos, chosenPath)
                guard dChosen > Self.offChosenM else { continue }
                let other = cp.options.filter { $0.id != s.way.optionId }
                    .map { ($0, Geo.distanceToPathM(pos, $0.path)) }
                    .filter { $0.1 < Self.onOtherM }
                    .min { $0.1 < $1.1 }
                if let (option, _) = other {
                    let total = cum.last ?? 0
                    let newPath = ChoicePointDetector.slice(path, cum: cum, from: 0, to: s.splitAlong) + option.path
                        + ChoicePointDetector.slice(path, cum: cum, from: s.rejoinAlong, to: total)
                    done.insert(s.way.choicePointId)
                    promptDone.insert(s.way.choicePointId)
                    path = newPath
                    cum = ChoicePointDetector.cumulative(newPath)
                    replans += 1
                    activeId = nil
                    rebuildStops()
                    return ChoicePromptUpdate(prompt: nil, newPath: newPath)
                }
            }
        }
        for s in stops {
            let id = s.way.choicePointId
            if alongM > s.rejoinAlong { done.insert(id) }
            if alongM > s.splitAlong + Self.passedM { promptDone.insert(id) }
        }
        guard !offPath, let next = stops.first(where: { !promptDone.contains($0.way.choicePointId) && $0.eligible }) else {
            activeId = nil
            return ChoicePromptUpdate(prompt: nil, newPath: nil)
        }
        let etaS = (next.splitAlong - alongM) / max(speedMps, Self.minSpeedMps)
        guard etaS <= Self.aheadS else {
            activeId = nil
            return ChoicePromptUpdate(prompt: nil, newPath: nil)
        }
        if activeId != next.way.choicePointId {
            activeId = next.way.choicePointId
            if counted.insert(next.way.choicePointId).inserted { shown += 1 }
        }
        return ChoicePromptUpdate(prompt: ChoicePrompt(id: next.way.choicePointId, text: next.text), newPath: nil)
    }
}
