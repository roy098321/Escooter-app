import Foundation

// N10-15 (batch 10): one occurrence of a fault, kept for the mechanic report: date (day number), km, minutes into the ride, and
// what the scooter reported at that moment. Never a place, a route or a time of day.

public struct FaultOccurrence: Codable, Equatable, Sendable {
    public var kind: FaultKind
    public var scooterId: String
    public var rideId: String?
    public var day: Int
    public var odoKm: Double?
    /// Minutes into the ride (event faults); nil for a whole-ride value or a park / charge
    public var minutesIn: Double?
    /// The fault's own number (mΩ, °C over the model, %, V, V/day, count)
    public var value: Double
    public var speedKmh: Double?
    public var currentA: Double?
    public var voltage: Double?
    public var tempC: Double?
    public var brake: Bool?
    public var airC: Double?
    /// Seconds from the ride's first reading (to cut the raw data around it); not a clock time
    public var rideT: Double?

    public init(kind: FaultKind, scooterId: String, rideId: String?, day: Int, odoKm: Double?, minutesIn: Double? = nil, value: Double,
                speedKmh: Double? = nil, currentA: Double? = nil, voltage: Double? = nil, tempC: Double? = nil, brake: Bool? = nil,
                airC: Double? = nil, rideT: Double? = nil) {
        self.kind = kind
        self.scooterId = scooterId
        self.rideId = rideId
        self.day = day
        self.odoKm = odoKm
        self.minutesIn = minutesIn
        self.value = value
        self.speedKmh = speedKmh
        self.currentA = currentA
        self.voltage = voltage
        self.tempC = tempC
        self.brake = brake
        self.airC = airC
        self.rideT = rideT
    }

    /// The reading just before time t (the moment of an event)
    public static func at(_ t: Double, in frames: [ScooterFrame]) -> ScooterFrame? {
        frames.last { $0.t < t } ?? frames.first
    }

    /// Occurrences for one ride: an event fault gives one per event (F2 cut, F3 brake run); a slow fault gives one per ride
    public static func fromRide(kinds: Set<FaultKind>, values: [FaultKind: Double], frames: [ScooterFrame], scooterId: String,
                                rideId: String?, day: Int, airC: Double?) -> [FaultOccurrence] {
        guard let t0 = frames.first?.t else { return [] }
        let odo = frames.last { $0.odometerKm != nil }?.odometerKm
        var out: [FaultOccurrence] = []
        func event(_ kind: FaultKind, _ times: [Double]) {
            for t in times {
                let f = at(t, in: frames)
                out.append(FaultOccurrence(kind: kind, scooterId: scooterId, rideId: rideId, day: day, odoKm: f?.odometerKm ?? odo,
                                           minutesIn: (t - t0) / 60, value: 1, speedKmh: f?.speedKmh, currentA: f?.currentA,
                                           voltage: f?.voltage, tempC: f?.temperatureC, brake: f?.brake, airC: airC, rideT: t - t0))
            }
        }
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch kind {
            case .f2PowerCut: event(kind, FaultDetectors.f2PowerCutTimes(frames))
            case .f3BrakeCut: event(kind, FaultDetectors.f3BrakeRuns(frames))
            default:
                let temps = frames.compactMap(\.temperatureC)
                out.append(FaultOccurrence(kind: kind, scooterId: scooterId, rideId: rideId, day: day, odoKm: odo,
                                           value: values[kind] ?? 0, voltage: frames.compactMap(\.voltage).min(),
                                           tempC: temps.max(), airC: airC))
            }
        }
        return out
    }

    /// Keep the newest `keep` per fault and scooter
    public static func append(_ list: [FaultOccurrence], _ new: [FaultOccurrence], keep: Int = 30) -> [FaultOccurrence] {
        var all = list + new
        for kind in Set(new.map(\.kind)) {
            let idx = all.indices.filter { all[$0].kind == kind }
            if idx.count > keep { for i in idx.prefix(idx.count - keep).reversed() { all.remove(at: i) } }
        }
        return all
    }
}
