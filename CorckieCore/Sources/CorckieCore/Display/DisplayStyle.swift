import Foundation

// M6-03 (C30): sunlight mode and the colour-blind speed colours, as pure rules the app (SwiftUI) and the replay page share.

/// When the sunlight style is on: Settings -> Sunlight mode (Auto / On / Off), the screen brightness, the time of day, and the
/// two iOS accessibility switches that ask for the same thing (Increase Contrast, Reduce Transparency).
public enum SunlightRule {
    /// Auto: the screen brightness slider at or above this (the rider turned it up to see the screen)
    public static let autoBrightness = 0.9
    /// Auto only in daylight hours (a bright screen at night is a choice, not the sun)
    public static let dayFromHour = 6
    public static let dayToHour = 20

    /// - Parameters:
    ///   - setting: "Auto" / "On" / "Off" (anything else counts as Auto)
    ///   - brightness: 0...1, nil when unknown
    ///   - hour: local hour of day 0...23
    public static func active(setting: String, brightness: Double?, hour: Int, increaseContrast: Bool = false,
                              reduceTransparency: Bool = false) -> Bool {
        switch setting {
        case "On": return true
        case "Off": return false
        default:
            if increaseContrast || reduceTransparency { return true }
            guard let b = brightness else { return false }
            return b >= autoBrightness && hour >= dayFromHour && hour < dayToHour
        }
    }
}

/// The five speed colours (slowest to fastest) of the path on the live map, the ride detail and the replay.
public enum SpeedPalette {
    public static let standardHex = ["#7FD37F", "#22B24C", "#F2D21B", "#F28C1B", "#E53935"]
    /// Okabe-Ito: blue -> sky -> yellow -> orange -> vermillion; no red / green pair
    public static let colourBlindHex = ["#0072B2", "#56B4E9", "#F0E442", "#E69F00", "#D55E00"]

    public static func hex(colourBlind: Bool) -> [String] { colourBlind ? colourBlindHex : standardHex }

    /// "#RRGGBB" -> 0...1 components (nil for anything else)
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    /// What the ride detail legend says
    public static func legendText(colourBlind: Bool) -> String {
        colourBlind ? "Colour = speed (dark blue slow, orange-red fast)" : "Colour = speed (light green slow, red fast)"
    }
}
