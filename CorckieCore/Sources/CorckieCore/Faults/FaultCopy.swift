import Foundation

// N10-12 (batch 10): what the rider reads and hears. Wording approved by the owner on 20 Nov 2026 (mock popup.png, switchon.png,
// simulator). Red = "Something isn't right" + the bold line "It's not safe to keep riding." on its own line; amber = a specific,
// assertive title; F16 = a grey info card with one OK. Never "OK to ride", never a green tick.

public struct FaultText: Equatable, Sendable {
    /// Pop-up title
    public var title: String
    /// What happened (one line under the title)
    public var line: String
    /// Red only: what to do, under "It's not safe to keep riding."
    public var todo: String?
    /// Row text on the Maintenance screen / part card
    public var row: String
    /// Fault page: what was found
    public var found: String
    /// Fault page: what to do
    public var what: String
}

public enum FaultCopy {
    public static let notSafe = "It's not safe to keep riding."
    public static let redTitle = "Something isn't right"

    /// The buttons, in order (solid · outlined · text)
    public static let tellMeMore = "Tell me more"
    public static let exportReport = "Export a report"
    public static let gotIt = "Got it"
    public static let checkedFine = "Checked, it's fine"
    public static let fixedIt = "I fixed it"

    public static func text(_ kind: FaultKind) -> FaultText {
        switch kind {
        case .f2PowerCut:
            return FaultText(title: redTitle, line: "Your scooter lost power while riding.",
                             todo: "Stop and check the battery plug before you ride again.", row: "Lost power while riding",
                             found: "The scooter switched itself off while riding faster than 10 km/h.",
                             what: "Check the battery plug. If it happens again, have the battery checked.")
        case .f3BrakeCut:
            return FaultText(title: redTitle, line: "Your brakes aren't cutting the motor.", todo: "Have the brake switch and controller checked.",
                             row: "Motor kept pushing while braking",
                             found: "The motor kept pushing for 3 or more seconds while the brake was on.",
                             what: "Have the brake switch and controller checked.")
        case .f1Sag:
            return FaultText(title: "Your battery needs checking",
                             line: "It strains more than usual under load on your last 3 rides. Have the plug and connectors checked.",
                             todo: nil, row: "Strains more than usual under load",
                             found: "Battery voltage drops more per amp than your normal, on 3 rides in similar weather.",
                             what: "Have the battery plug and connectors checked.")
        case .f5Tyre:
            return FaultText(title: "Your tyre needs checking", line: "It may be soft or worn. Check the pressure.", todo: nil,
                             row: "May be soft or worn",
                             found: "Over your last 10 rides on the same route, the wheel counts a different distance than GPS than it used to.",
                             what: "Check the tyre pressure. Look at the tread.")
        case .f6Heat:
            return FaultText(title: "Your motor needs checking",
                             line: "It has run much hotter than it should on your last 3 rides. Book a mechanic soon.", todo: nil,
                             row: "Ran hot on your last 3 rides",
                             found: "Your motor ran 10 °C or more hotter than it should on your last 3 rides, compared with rides of the same effort and weather.",
                             what: "Have the motor checked by a mechanic.")
        case .f7Sensor:
            return FaultText(title: "Your wiring needs checking",
                             line: "A sensor gave impossible readings on 2 rides. Have the motor cable checked.", todo: nil,
                             row: "Sensor readings that can't be right",
                             found: "The temperature or wheel-speed signal jumped or dropped out in ways a working sensor can't, on 2 rides.",
                             what: "Have the motor cable and its connector checked.")
        case .f11ParkedDrain:
            return FaultText(title: "Your battery needs checking", line: "It lost more charge while parked than it should, with nothing switched on.",
                             todo: nil, row: "Loses charge while parked",
                             found: "Resting voltage dropped more than this scooter's normal while parked, on 3 parks.",
                             what: "Have the battery checked for a weak cell.")
        case .f12FullVoltage:
            return FaultText(title: "Your charger needs checking", line: "Your battery shows full but isn't fully charged.", todo: nil,
                             row: "Charger not filling the battery",
                             found: "After the last 3 charges the battery rested well below your usual full voltage.",
                             what: "Have the charger's output measured.")
        case .f16OdoReset:
            return FaultText(title: "Km counter reset", line: "Maintenance reminders now count from here.", todo: nil,
                             row: "Km counter reset", found: "The scooter's km counter went back or to zero.",
                             what: "Nothing to do. Reminders restart from the new number.")
        }
    }

    // MARK: in-ride voice (L3: icon + voice + vibration), F2 and F3 only

    public static let voicePowerCut2 = "Power cut twice. Slow down and check the battery plug."
    public static let voicePowerCut4 = "Power cut four times. Stop and check the battery plug."
    public static let voiceBrake = "Brakes aren't cutting the motor when braking, check the brake switch and controller."
}

/// N10-2 / N10-3: the in-ride voice lines. F2: the 2nd and the 4th cut in one ride. F3: a brake run on a ride after one was
/// already found (said right after the braking ends). A new rider (still learning) hears nothing.
public struct LiveFaultVoice: Sendable {
    public private(set) var cuts = 0
    public private(set) var brakeSaid = false
    let learned: Bool
    let brakeFoundBefore: Bool

    public init(learned: Bool, brakeFoundBefore: Bool) {
        self.learned = learned
        self.brakeFoundBefore = brakeFoundBefore
    }

    /// A power cut at speed happened (FaultDetectors.f2 rule): the line to say, if any
    public mutating func powerCut() -> String? {
        cuts += 1
        guard learned else { return nil }
        switch cuts {
        case 2: return FaultCopy.voicePowerCut2
        case 4: return FaultCopy.voicePowerCut4
        default: return nil
        }
    }

    /// A 3-second brake + current run just ended: the line to say, once per ride, only when it was found on an earlier ride
    public mutating func brakeRunEnded() -> String? {
        guard learned, brakeFoundBefore, !brakeSaid else { return nil }
        brakeSaid = true
        return FaultCopy.voiceBrake
    }
}
