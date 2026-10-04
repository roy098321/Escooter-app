import CorckieCore
import Foundation

/// What the phone reports during a replay (M1-02): GPS fixes, barometer readings and the
/// phone-side events the fault markers stand for. Replayed on the same virtual clock as the
/// scooter packets, so the ride engine sees one timeline, exactly as on the street.
public enum PhoneEvent: Equatable, Sendable {
    case fix(PhoneFix)
    case baro(BaroReading)
    /// The phone has / has no internet (`offline` fault)
    case offline(Bool)
    /// Phone battery level in % (`phoneBattery` fault)
    case phoneBattery(pct: Int)
    /// The app was killed and relaunched by iOS (`appRelaunch` fault)
    case appRelaunch
    /// An outside service is down (`serviceDown` fault)
    case serviceDown(String)
}

public struct TimedPhoneEvent: Equatable, Sendable {
    public var t: Double
    public var event: PhoneEvent

    public init(t: Double, event: PhoneEvent) {
        self.t = t
        self.event = event
    }

    public var fix: PhoneFix? {
        if case .fix(let f) = event { return f }
        return nil
    }

    public var baro: BaroReading? {
        if case .baro(let b) = event { return b }
        return nil
    }
}

/// Scooter packets + phone events of one replay or one synthetic ride.
public struct SimStream: Sendable {
    public var scooter: [TimedScooterEvent]
    public var phone: [TimedPhoneEvent]

    public init(scooter: [TimedScooterEvent], phone: [TimedPhoneEvent]) {
        self.scooter = scooter
        self.phone = phone
    }

    /// Stream faults go to the scooter side, phone faults to the phone side.
    public func applying(_ faults: [Fault], seed: UInt64 = 42) -> SimStream {
        SimStream(scooter: FaultInjector.apply(faults, to: scooter, seed: seed),
                  phone: PhoneSource.apply(faults, to: phone))
    }
}

public enum PhoneSource {
    /// Horizontal accuracy given to fixes rebuilt from a 1-per-second log (a good fix, T28)
    public static let defaultAccuracyM = 5.0

    /// GPS and barometer from a 1-per-second merged log (F3): one fix and one reading a second.
    public static func events(fromMerged samples: [MergedSample], accuracyM: Double = defaultAccuracyM) -> [TimedPhoneEvent] {
        var out: [TimedPhoneEvent] = []
        for s in samples {
            if let lat = s.lat, let lon = s.lon {
                let speed = s.gpsSpeedKmh.map { $0 / 3.6 } ?? -1
                out.append(TimedPhoneEvent(t: s.t, event: .fix(PhoneFix(t: s.t, lat: lat, lon: lon, hAccM: accuracyM, speedMps: speed))))
            }
            if let rel = s.elevBaroM {
                out.append(TimedPhoneEvent(t: s.t, event: .baro(BaroReading(t: s.t, relativeAltitudeM: rel))))
            }
        }
        return out
    }

    /// GPS and barometer as the phone recorded them (F4, Sensor Logger), put on the scooter log's
    /// clock. `scooterStartTimeOfDayS` is the scooter log's first row (seconds after midnight, local),
    /// `utcOffsetS` the phone's local offset (the fixtures keep the original clock times).
    public static func events(locationText: String, barometerText: String,
                              scooterStartTimeOfDayS: Double, utcOffsetS: Double = 10_800) throws -> [TimedPhoneEvent] {
        let fixes = try LogReader.sensorLoggerLocation(locationText)
        let baro = try LogReader.sensorLoggerBarometer(barometerText)
        let locZero = LogReader.sensorLoggerEpochZeroS(locationText) ?? 0
        let baroZero = LogReader.sensorLoggerEpochZeroS(barometerText) ?? locZero
        func onScooterClock(_ epochZero: Double, _ elapsed: Double) -> Double {
            var t = (epochZero + elapsed).truncatingRemainder(dividingBy: 86_400) - (scooterStartTimeOfDayS - utcOffsetS)
            if t < -43_200 { t += 86_400 }
            if t > 43_200 { t -= 86_400 }
            return t
        }
        var out: [TimedPhoneEvent] = []
        for var f in fixes {
            f.t = onScooterClock(locZero, f.t)
            out.append(TimedPhoneEvent(t: f.t, event: .fix(f)))
        }
        for var b in baro {
            b.t = onScooterClock(baroZero, b.t)
            out.append(TimedPhoneEvent(t: b.t, event: .baro(b)))
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Makes the phone-side fault markers real: GPS loss and barometer stop remove readings,
    /// offline / battery / relaunch / service-down add events. Stream faults are ignored here.
    public static func apply(_ faults: [Fault], to input: [TimedPhoneEvent]) -> [TimedPhoneEvent] {
        var events = input
        for fault in faults {
            switch fault {
            case let .gpsLoss(from, to):
                events.removeAll { $0.fix != nil && $0.t >= from && $0.t <= to }
            case let .barometerStop(at):
                events.removeAll { $0.baro != nil && $0.t >= at }
            case let .offline(from, to):
                events.append(TimedPhoneEvent(t: from, event: .offline(true)))
                events.append(TimedPhoneEvent(t: to, event: .offline(false)))
            case let .phoneBattery(at, pct):
                events.append(TimedPhoneEvent(t: at, event: .phoneBattery(pct: pct)))
            case let .appRelaunch(at):
                events.append(TimedPhoneEvent(t: at, event: .appRelaunch))
            case let .serviceDown(name):
                events.append(TimedPhoneEvent(t: events.map(\.t).min() ?? 0, event: .serviceDown(name)))
            case .disconnect, .packetLoss, .corruptBytes, .speedSpike, .batterySpike, .shutdown:
                break
            }
        }
        return events.sorted { $0.t < $1.t }
    }
}
