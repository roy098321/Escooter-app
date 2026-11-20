import Foundation

// N10-12 (batch 10): after a ride, every fault's number goes through the gate; at most ONE finding reaches the pop-up over the
// ride summary. Switch-on checks (F11 parked drain, F12 voltage at full, F16 counter reset across a park) run when the scooter
// connects. Pure logic: the App layer stores the FaultBook and shows the pop-up.

/// Why a ride doesn't count for some faults (HARSH RULE: rule out the normal causes)
public struct FaultRuleOuts: Equatable, Sendable {
    public var airC: Double?
    /// Lowest battery % on the ride
    public var minBatteryPct: Int?
    /// GPS too weak to compare with the wheel
    public var weakGps = false
    /// The phone's Bluetooth dropped the scooter several times (gaps in the readings)
    public var phoneLinkTrouble = false
    /// Climb per km above the rider's usual (hills)
    public var hilly = false
    /// Strong head wind for most of the ride
    public var windy = false

    public init(airC: Double? = nil, minBatteryPct: Int? = nil, weakGps: Bool = false, phoneLinkTrouble: Bool = false,
                hilly: Bool = false, windy: Bool = false) {
        self.airC = airC
        self.minBatteryPct = minBatteryPct
        self.weakGps = weakGps
        self.phoneLinkTrouble = phoneLinkTrouble
        self.hilly = hilly
        self.windy = windy
    }

    /// Below this the battery sags more by itself; above it everything runs hot
    public static let coldC = 5.0, hotC = 35.0
    public static let lowBatteryPct = 20

    /// The faults this ride can't judge
    public var ruledOut: Set<FaultKind> {
        var out: Set<FaultKind> = []
        let extremeAir = airC.map { $0 < Self.coldC || $0 > Self.hotC } ?? false
        if extremeAir || hilly || windy { out.formUnion([.f1Sag, .f6Heat]) }
        if airC == nil { out.insert(.f6Heat) }   // the heat model needs the air temperature
        if let b = minBatteryPct, b < Self.lowBatteryPct { out.insert(.f1Sag) }
        if weakGps { out.formUnion([.f5Tyre, .f7Sensor]) }
        if phoneLinkTrouble { out.formUnion([.f1Sag, .f7Sensor]) }
        return out
    }
}

/// One ride as the fault check sees it
public struct RideFaultInput: Sendable {
    public var scooterId: String
    public var firmware: String?
    public var frames: [ScooterFrame]
    public var day: Int
    public var ruleOuts: FaultRuleOuts
    /// Saved route id and this route's wheel/GPS ratios, oldest first, this ride last (nil when not on a saved route)
    public var routeId: String?
    public var routeRatios: [Double]
    /// Motor rise over the air, effort and minutes for this ride (nil without temperature or air)
    public var heat: FaultDetectors.HeatPoint?
    public var gpsKmhAt: @Sendable (Double) -> Double?
    public var linkDropTimes: [Double]
    /// Odometer at the end of the previous ride on this scooter
    public var previousOdoKm: Double?

    public init(scooterId: String, firmware: String? = nil, frames: [ScooterFrame], day: Int, ruleOuts: FaultRuleOuts = FaultRuleOuts(),
                routeId: String? = nil, routeRatios: [Double] = [], heat: FaultDetectors.HeatPoint? = nil,
                gpsKmhAt: @escaping @Sendable (Double) -> Double? = { _ in nil }, linkDropTimes: [Double] = [], previousOdoKm: Double? = nil) {
        self.scooterId = scooterId
        self.firmware = firmware
        self.frames = frames
        self.day = day
        self.ruleOuts = ruleOuts
        self.routeId = routeId
        self.routeRatios = routeRatios
        self.heat = heat
        self.gpsKmhAt = gpsKmhAt
        self.linkDropTimes = linkDropTimes
        self.previousOdoKm = previousOdoKm
    }
}

/// What the check found: every finding (for the Maintenance screen) and the one to show now
public struct FaultReport: Equatable, Sendable {
    public var findings: [FaultFinding]
    public var show: FaultFinding? { FaultFinding.pickOne(findings) }
    /// Firmware changed: every fault started learning again (A29)
    public var relearned: Bool
}

/// Heat model points per scooter (F6 needs the rides, not just one number)
public struct HeatBook: Codable, Equatable, Sendable {
    public var points: [String: [FaultDetectors.HeatPoint]] = [:]
    public init() {}
    public static let keep = 60
}

public enum AfterRideFaults {

    /// Run one finished ride through every after-ride fault. Updates the books.
    public static func run(_ r: RideFaultInput, book: inout FaultBook, heat: inout HeatBook) -> FaultReport {
        var relearned = false
        if let fw = r.firmware {
            relearned = book.noteFirmware(fw, scooterId: r.scooterId)
            if relearned { heat.points[r.scooterId] = nil }
        }
        let out = r.ruleOuts.ruledOut
        var findings: [FaultFinding] = []

        func gate(_ kind: FaultKind, _ value: Double?, variant: String = "", minGap: Double = 0, atLeast: Double? = nil) {
            guard let value else { return }
            let b = book.baseline(r.scooterId, kind, variant)
            let bar = FaultGate.bar(b, kind: kind, minGap: minGap, atLeast: atLeast)
            let (verdict, nb) = FaultGate.evaluate(b, kind: kind, value: value, ruledOut: out.contains(kind), minGap: minGap,
                                                   atLeast: atLeast, day: r.day)
            book.set(nb, r.scooterId, kind, variant)
            if case .alert(let v) = verdict {
                let excess = bar.map { abs(v - $0) / max(abs($0), 1e-9) } ?? 1
                findings.append(FaultFinding(kind: kind, value: v, excess: excess))
            }
        }

        // F1 battery strain, per air band
        gate(.f1Sag, FaultDetectors.f1SagMilliohm(r.frames), variant: FaultDetectors.f1Band(airC: r.ruleOuts.airC))
        // F2 power cuts / F3 brake runs: counts per ride (0 on a healthy ride is learned as normal)
        gate(.f2PowerCut, Double(FaultDetectors.f2PowerCutTimes(r.frames).count))
        gate(.f3BrakeCut, Double(FaultDetectors.f3BrakeRuns(r.frames).count))
        // F5 tyre, per route (3 % step + 10 %)
        if let route = r.routeId {
            gate(.f5Tyre, FaultDetectors.f5ShiftPct(routeRatios: r.routeRatios), variant: route, minGap: 3)
        }
        // F6 heat: the model is fitted on earlier normal rides only (10 first); then the gate learns 10 rides of "over the model"
        // before it can speak, so F6 needs about 20 rides (HARSH RULE)
        if let p = r.heat {
            let pts = heat.points[r.scooterId] ?? []
            let over = FaultDetectors.f6Model(pts).map { FaultDetectors.f6OverModelC(p, model: $0) }
            gate(.f6Heat, over, atLeast: FaultDetectors.f6LineC)
            if !out.contains(.f6Heat), (over ?? 0) < FaultDetectors.f6LineC {
                var list = pts + [p]
                if list.count > HeatBook.keep { list.removeFirst(list.count - HeatBook.keep) }
                heat.points[r.scooterId] = list
            }
        }
        // F7 impossible readings
        gate(.f7Sensor, FaultDetectors.f7Score(r.frames, gpsKmhAt: r.gpsKmhAt, linkDropTimes: r.linkDropTimes),
             atLeast: FaultDetectors.f7Line)
        // F16 km counter: backwards / near 0 since the last ride, or a held jump in the ride
        let firstOdo = r.frames.lazy.compactMap(\.odometerKm).first
        if FaultDetectors.f16Reset(previousKm: r.previousOdoKm, nowKm: firstOdo) || FaultDetectors.f16JumpInRide(r.frames) {
            gate(.f16OdoReset, 1)
        }
        return FaultReport(findings: findings, relearned: relearned)
    }

    /// Switch-on: a park (F11) and the first resting voltage after a charge (F12). `charged` = the voltage rose across the park.
    public static func switchOn(scooterId: String, day: Int, park: (startV: Double, endV: Double, hours: Double, odoStartKm: Double?,
                                                                    odoEndKm: Double?)?,
                                firstFrames: [ScooterFrame], charged: Bool, book: inout FaultBook) -> FaultReport {
        var findings: [FaultFinding] = []
        func gate(_ kind: FaultKind, _ value: Double?, minGap: Double = 0) {
            guard let value else { return }
            let b = book.baseline(scooterId, kind)
            let bar = FaultGate.bar(b, kind: kind, minGap: minGap)
            let (verdict, nb) = FaultGate.evaluate(b, kind: kind, value: value, minGap: minGap, day: day)
            book.set(nb, scooterId, kind)
            if case .alert(let v) = verdict {
                findings.append(FaultFinding(kind: kind, value: v, excess: bar.map { abs(v - $0) / max(abs($0), 1e-9) } ?? 1))
            }
        }
        // the rider's lowest normal full voltage, for the "starts near full" park rule
        let full = book.baseline(scooterId, .f12FullVoltage).samples.min()
        if charged {
            gate(.f12FullVoltage, FaultDetectors.f12RestingVoltage(firstFrames), minGap: FaultDetectors.f12StepV)
        } else if let p = park {
            gate(.f11ParkedDrain, FaultDetectors.f11DrainVPerDay(startV: p.startV, endV: p.endV, hours: p.hours, odoStartKm: p.odoStartKm,
                                                                 odoEndKm: p.odoEndKm, fullV: full), minGap: 0.05)
            if FaultDetectors.f16Reset(previousKm: p.odoStartKm, nowKm: p.odoEndKm) { gate(.f16OdoReset, 1) }
        }
        return FaultReport(findings: findings, relearned: false)
    }
}
