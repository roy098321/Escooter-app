import Foundation

/// M4-06: heat on the ride summary (M38, CALC_SPEC 7). The live "hot" / "very hot" banners are M1-07; this adds the after-ride cards:
/// - Peak: "Peak 92 °C · +68 °C" when the ride reached the hot level (class safety);
/// - S6 hot day: air temperature 30 °C or more and the ride ran 5 °C or more hotter than the route's median rise;
/// - S7 ran hotter: heating rate 30% or more above the route's median in similar air temperature (within 5 °C), route 5 rides or more (T48).
/// Heating rate here = temperature rise per km of the ride (the km at more than 15 km/h are not stored; see P5_DILEMMAS D9).
/// A hot day explains a hotter ride, so S7 is not made when S6 is.

public struct HeatRide: Equatable, Sendable {
    public var riseC: Double?
    public var distanceKm: Double
    public var airTempC: Double?

    public init(riseC: Double?, distanceKm: Double, airTempC: Double?) {
        self.riseC = riseC
        self.distanceKm = distanceKm
        self.airTempC = airTempC
    }

    /// °C per km
    public var rate: Double? {
        guard let r = riseC, distanceKm >= 1 else { return nil }
        return r / distanceKm
    }
}

/// S1: the learned heat limit. 2 or more protection events (temperature 70 °C or more while the rider asks for full power but the
/// current stays below 90% of the learned maximum for 5 s) move the warnings to 5 °C below the lowest event temperature.
public enum HeatLimits {
    public static let eventMinTempC = 70.0
    public static let veryHotGapC = T.t47VeryHotC - T.t47HotC

    public static func limits(eventTempsC: [Double]) -> (hotC: Double, veryHotC: Double) {
        guard eventTempsC.count >= T.t47LearnedAfterEvents, let lowest = eventTempsC.min() else { return (T.t47HotC, T.t47VeryHotC) }
        let hot = lowest - T.t47LearnedMarginC
        return (hot, hot + veryHotGapC)
    }
}

extension InsightCatalogue {
    public static let hotDayAirC = 30.0
    public static let hotDayExtraRiseC = 5.0
    public static let heatMinRides = 5
    public static let similarAirC = 5.0

    public static func heatPeak(rideId: String, routeId: String?, peakC: Double?, riseC: Double?, hotC: Double = T.t47HotC, nowMs: Int64) -> [Insight] {
        guard let peak = peakC, peak >= hotC else { return [] }
        var text = "Peak \(Int(peak.rounded())) \u{00B0}C"
        if let rise = riseC, rise >= 1 { text += " \u{00B7} +\(Int(rise.rounded())) \u{00B0}C" }
        return [Insight(type: .heatPeak, rideId: rideId, routeId: routeId, text: text, basedOnN: 1, createdAt: nowMs)]
    }

    public static func heatHotDay(rideId: String, routeId: String, ride: HeatRide, routeRides: [HeatRide], nowMs: Int64) -> [Insight] {
        guard let air = ride.airTempC, air >= hotDayAirC, let rise = ride.riseC else { return [] }
        let rises = routeRides.compactMap(\.riseC)
        guard rises.count >= heatMinRides, let median = Geo.median(rises), rise - median >= hotDayExtraRiseC else { return [] }
        let text = "Hot day (\(Int(air.rounded())) \u{00B0}C): scooter ran \(Int((rise - median).rounded())) \u{00B0}C hotter than usual on this route \u{00B7} \(InsightText.basedOn(rises.count))."
        return [Insight(type: .heatHotDay, rideId: rideId, routeId: routeId, text: text, basedOnN: rises.count, createdAt: nowMs)]
    }

    public static func heatRanHotter(rideId: String, routeId: String, ride: HeatRide, routeRides: [HeatRide], nowMs: Int64) -> [Insight] {
        guard let rate = ride.rate else { return [] }
        let similar = routeRides.filter { r in
            guard let a = ride.airTempC, let b = r.airTempC else { return true }       // no air temperature: all rides compared
            return abs(a - b) <= similarAirC
        }.compactMap(\.rate)
        guard similar.count >= heatMinRides, let median = Geo.median(similar), median > 0, rate >= median * (1 + T.t48HotterRate) else { return [] }
        let more = Int(((rate / median - 1) * 100).rounded())
        let text = "Ran hotter than usual (+\(more)% heating): tyres, brakes, load? \u{00B7} \(InsightText.basedOn(similar.count))."
        return [Insight(type: .heatRanHotter, rideId: rideId, routeId: routeId, text: text, basedOnN: similar.count, createdAt: nowMs)]
    }

    /// All three for one ride, S6 before S7 (a hot day explains a hotter ride)
    public static func heatAfter(rideId: String, routeId: String?, peakC: Double?, ride: HeatRide, routeRides: [HeatRide], hotC: Double = T.t47HotC,
                                 nowMs: Int64) -> [Insight] {
        var out = heatPeak(rideId: rideId, routeId: routeId, peakC: peakC, riseC: ride.riseC, hotC: hotC, nowMs: nowMs)
        guard let routeId else { return out }
        let hotDay = heatHotDay(rideId: rideId, routeId: routeId, ride: ride, routeRides: routeRides, nowMs: nowMs)
        out += hotDay.isEmpty ? heatRanHotter(rideId: rideId, routeId: routeId, ride: ride, routeRides: routeRides, nowMs: nowMs) : hotDay
        return out
    }
}
