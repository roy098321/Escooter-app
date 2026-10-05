import Foundation

/// M2-04: one row of the Routes list (name, how many rides, usual time and battery ranges). Greying and chips come with M2-05.
public struct RouteListInput: Sendable {
    public var routeId: String
    public var title: String
    public var state: RouteState
    public var rides: [RouteRideStats]
    public var nowMs: Int64
    /// M2-05 greying: rides on the opposite route (the way back), the battery now, and "I can charge here" on the end place
    public var reverseRides: [RouteRideStats]
    public var battery: BatteryNow?
    public var canChargeAtEnd: Bool
    public var utcOffsetMin: Int

    public init(routeId: String, title: String, state: RouteState, rides: [RouteRideStats], nowMs: Int64,
                reverseRides: [RouteRideStats] = [], battery: BatteryNow? = nil, canChargeAtEnd: Bool = false, utcOffsetMin: Int = 0) {
        self.routeId = routeId
        self.title = title
        self.state = state
        self.rides = rides
        self.nowMs = nowMs
        self.reverseRides = reverseRides
        self.battery = battery
        self.canChargeAtEnd = canChargeAtEnd
        self.utcOffsetMin = utcOffsetMin
    }
}

public struct RouteListRow: Equatable, Sendable {
    public var routeId: String
    public var title: String
    public var state: RouteState
    public var rideCount: Int
    /// "14 rides · 12–15 min · 9–11%", or "2 rides · filling up"
    public var summary: String
    /// Newest ride, for ordering
    public var lastRideAt: Int64
    /// M2-05: the battery check (grey, chip, one honest line); `.silent` for suggested routes and without data
    public var fit: RouteFitResult = .silent
}

public struct RouteListModel: Equatable, Sendable {
    public var saved: [RouteListRow]
    public var suggested: [RouteListRow]
    public var isEmpty: Bool { saved.isEmpty && suggested.isEmpty }

    public init(saved: [RouteListRow], suggested: [RouteListRow]) {
        self.saved = saved
        self.suggested = suggested
    }
}

public enum RouteListBuilder {
    public static func row(_ input: RouteListInput) -> RouteListRow {
        let n = input.rides.count
        var parts = ["\(n) \(n == 1 ? "ride" : "rides")"]
        let selected = UsualRange.select(input.rides, nowMs: input.nowMs)
        if let t = UsualRange.range(of: .time, rides: selected) {
            parts.append(RouteCardBuilder.rangeText(.time, t))
            if let b = UsualRange.range(of: .battery, rides: selected) { parts.append(RouteCardBuilder.rangeText(.battery, b)) }
        } else {
            parts.append("filling up")
        }
        return RouteListRow(routeId: input.routeId, title: input.title, state: input.state, rideCount: n,
                            summary: parts.joined(separator: " \u{00B7} "), lastRideAt: input.rides.map { $0.startAt }.max() ?? 0,
                            fit: fit(input))
    }

    /// M27 / G2: only saved routes are judged. Both legs use `neededPct` (the 10% margin), the way back at its usual time.
    public static func fit(_ input: RouteListInput) -> RouteFitResult {
        guard input.state == .saved, input.battery != nil else { return .silent }
        guard case .estimate(let there) = TodayEstimator.estimate(rides: input.rides, nowMs: input.nowMs, utcOffsetMin: input.utcOffsetMin) else {
            return .silent
        }
        var back: Double?
        if case .estimate(let b) = TodayEstimator.estimate(rides: input.reverseRides, nowMs: input.nowMs, utcOffsetMin: input.utcOffsetMin) {
            back = b.neededPct
        }
        return RouteFit.evaluate(thereNeededPct: there.neededPct, thereUsedPct: there.usedPct, backNeededPct: back, battery: input.battery,
                                 canChargeAtEnd: input.canChargeAtEnd)
    }

    /// Saved routes by their newest ride, suggestions apart; dismissed routes are never listed.
    public static func build(_ inputs: [RouteListInput]) -> RouteListModel {
        let rows = inputs.filter { $0.state != .dismissed }.map { row($0) }
        let newestFirst: (RouteListRow, RouteListRow) -> Bool = { $0.lastRideAt > $1.lastRideAt }
        return RouteListModel(saved: rows.filter { $0.state == .saved }.sorted(by: newestFirst),
                              suggested: rows.filter { $0.state == .suggested }.sorted(by: newestFirst))
    }
}
