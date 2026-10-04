import Foundation

/// M1-16: which on-device ride checks tick themselves from the real recorded rides (M1_PLAN section 4.3).
/// Pure rules over a few facts per ride; `App/Diagnostics/RideChecks.swift` reads the facts from the database.
/// Simulated rides, short hops and discarded pieces never count.
public struct RideFacts: Equatable, Sendable {
    public var id: String
    public var startAtMs: Int64
    public var utcOffsetMin: Int
    public var kind: String
    public var status: String
    public var endReason: String?
    public var isSimulated: Bool
    public var totalS: Double
    public var distanceM: Double?
    public var odoStartKm: Double?
    public var odoEndKm: Double?
    public var topSpeedMps: Double?
    public var sampleCount: Int
    /// seconds above 45 km/h (counted from the stored samples, 5 s each)
    public var secondsOverLimit: Double
    public var gapScooterS: Double
    public var mergeGroupId: String?

    public init(id: String, startAtMs: Int64, utcOffsetMin: Int = 0, kind: String = "ride", status: String = "ended",
                endReason: String? = nil, isSimulated: Bool = false, totalS: Double = 0, distanceM: Double? = nil,
                odoStartKm: Double? = nil, odoEndKm: Double? = nil, topSpeedMps: Double? = nil, sampleCount: Int = 0,
                secondsOverLimit: Double = 0, gapScooterS: Double = 0, mergeGroupId: String? = nil) {
        self.id = id
        self.startAtMs = startAtMs
        self.utcOffsetMin = utcOffsetMin
        self.kind = kind
        self.status = status
        self.endReason = endReason
        self.isSimulated = isSimulated
        self.totalS = totalS
        self.distanceM = distanceM
        self.odoStartKm = odoStartKm
        self.odoEndKm = odoEndKm
        self.topSpeedMps = topSpeedMps
        self.sampleCount = sampleCount
        self.secondsOverLimit = secondsOverLimit
        self.gapScooterS = gapScooterS
        self.mergeGroupId = mergeGroupId
    }
}

public struct RideCheckVerdict: Equatable, Sendable {
    public enum Result: String, Sendable { case pass, fail, info }
    public let id: String
    public let result: Result
    public let note: String
}

public enum RideCheckRules {
    /// One sample every 5 s; a ride counts as fully sampled from 95%.
    public static let sampleStepS = 5.0

    public static func evaluate(_ all: [RideFacts]) -> [RideCheckVerdict] {
        let real = all.filter { !$0.isSimulated && $0.kind == "ride" && ($0.status == "ended" || $0.status == "recovered") }
            .sorted { $0.startAtMs < $1.startAtMs }
        guard !real.isEmpty else { return [] }
        var out: [RideCheckVerdict] = []

        // x1: a real commute, sampled without gaps, ended by a rule
        if let ride = real.last(where: { $0.status == "ended" && $0.endReason != nil && $0.totalS >= 300 }) {
            let pct = coverage(ride)
            out.append(RideCheckVerdict(id: "x1", result: pct >= 95 ? .pass : .fail,
                                        note: "\(Int(pct.rounded()))% of seconds sampled, ended by \(ride.endReason ?? "?")"))
        }

        // x2: two rides on the same local day
        var perDay: [Int64: Int] = [:]
        for ride in real { perDay[day(ride), default: 0] += 1 }
        if let busy = perDay.values.max(), busy >= 2 {
            out.append(RideCheckVerdict(id: "x2", result: .pass, note: "\(busy) rides on one day"))
        }

        // s2: the numbers of the newest ride, recorded
        if let last = real.last {
            let km = (last.distanceM ?? 0) / 1000
            out.append(RideCheckVerdict(id: "s2", result: .info,
                                        note: "Newest ride: \(Int(last.totalS / 60)) min, \(String(format: "%.1f", km)) km, top \(String(format: "%.0f", (last.topSpeedMps ?? 0) * 3.6)) km/h"))
        }

        // s3: distance integrated from speed within 3% of the odometer bytes
        let withOdo = real.filter { ($0.odoStartKm != nil) && ($0.odoEndKm != nil) && ($0.distanceM ?? 0) > 500 }
        if !withOdo.isEmpty {
            var worst = 0.0
            for ride in withOdo {
                let odo = ((ride.odoEndKm ?? 0) - (ride.odoStartKm ?? 0)) * 1000
                guard odo > 0, let d = ride.distanceM else { continue }
                worst = max(worst, abs(d - odo) / odo * 100)
            }
            out.append(RideCheckVerdict(id: "s3", result: worst <= 3 ? .pass : .fail,
                                        note: "Largest difference \(String(format: "%.1f", worst))% over \(withOdo.count) ride(s)"))
        }

        // s5: the first real ride exists
        out.append(RideCheckVerdict(id: "s5", result: .pass, note: "First real ride recorded"))

        // e2m: a switch-off ended a ride at once
        if let off = real.last(where: { $0.endReason == "scooterOff" }) {
            out.append(RideCheckVerdict(id: "e2m", result: .pass, note: "Ride ended by scooterOff (\(Int(off.totalS / 60)) min)"))
        }

        // e3m: two pieces joined by Same ride
        if real.contains(where: { $0.mergeGroupId != nil }) {
            out.append(RideCheckVerdict(id: "e3m", result: .pass, note: "A ride was joined from two pieces"))
        }

        // w4: speed warning on real rides, recorded for tuning
        let red = real.reduce(0.0) { $0 + $1.secondsOverLimit }
        let top = real.compactMap { $0.topSpeedMps }.max() ?? 0
        let redRides = real.filter { $0.secondsOverLimit > 0 }.count
        out.append(RideCheckVerdict(id: "w4", result: .info,
                                    note: "\(redRides) of \(real.count) rides over 45 km/h, \(Int(red)) s in all, top \(String(format: "%.0f", top * 3.6)) km/h"))

        // b9m: link over rides, recorded
        let gaps = real.filter { $0.gapScooterS > 0 }
        out.append(RideCheckVerdict(id: "b9m", result: .info,
                                    note: "\(gaps.count) of \(real.count) rides had scooter gaps, \(Int(gaps.reduce(0.0) { $0 + $1.gapScooterS })) s in all"))
        return out
    }

    static func coverage(_ ride: RideFacts) -> Double {
        guard ride.totalS > 0 else { return 0 }
        return min(100, Double(ride.sampleCount) * sampleStepS / ride.totalS * 100)
    }

    /// Local calendar day number of the ride start
    static func day(_ ride: RideFacts) -> Int64 {
        (ride.startAtMs / 1000 + Int64(ride.utcOffsetMin) * 60) / 86_400
    }
}
