import Foundation

/// M5-02: the two ends of a ride, for "Merge with previous?" (the M1-04 "Same ride?" rule, applied later from the ride list).
public struct MergeEnd: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var endAt: Int64?
    public var startLat: Double?
    public var startLon: Double?
    public var endLat: Double?
    public var endLon: Double?
    public var isSimulated: Bool
    public var kind: String

    public init(id: String, startAt: Int64, endAt: Int64?, startLat: Double? = nil, startLon: Double? = nil,
                endLat: Double? = nil, endLon: Double? = nil, isSimulated: Bool = false, kind: String = "ride") {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.startLat = startLat
        self.startLon = startLon
        self.endLat = endLat
        self.endLon = endLon
        self.isSimulated = isSimulated
        self.kind = kind
    }
}

public struct MergeOffer: Equatable, Sendable {
    public var gapS: Double
    public var gapM: Double

    public init(gapS: Double, gapM: Double) {
        self.gapS = gapS
        self.gapM = gapM
    }

    /// "Stopped 12 min, 80 m from where this ride started"
    public var text: String {
        "Stopped \(RideSummaryBuilder.duration(gapS)), \(Int(gapM.rounded())) m from where this ride started"
    }
}

public enum RideMerge {
    /// C18: the previous ride ended 30 min or less before this one started ...
    public static let maxGapS = 30.0 * 60
    /// ... and 200 m or less away
    public static let maxGapM = 200.0

    /// An offer when `next` can be joined to `previous`; nil otherwise (discarded, real with simulated, overlapping, too late, too far, unknown place).
    public static func offer(previous: MergeEnd, next: MergeEnd) -> MergeOffer? {
        guard previous.id != next.id, previous.isSimulated == next.isSimulated,
              previous.kind != "discarded", next.kind != "discarded",
              let end = previous.endAt, next.startAt >= end else { return nil }
        let gapS = Double(next.startAt - end) / 1000
        guard gapS <= maxGapS,
              let la = previous.endLat, let lo = previous.endLon, let lb = next.startLat, let ob = next.startLon else { return nil }
        let gapM = Geo.distanceM(GeoPoint(lat: la, lon: lo), GeoPoint(lat: lb, lon: ob))
        guard gapM <= maxGapM else { return nil }
        return MergeOffer(gapS: gapS, gapM: gapM)
    }

    /// Milliseconds to add to the second ride's sample times so they continue after the first ride (both are ms from their own start).
    public static func shiftMs(firstStartAt: Int64, secondStartAt: Int64) -> Int64 {
        secondStartAt - firstStartAt
    }
}
