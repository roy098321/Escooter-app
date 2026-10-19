import Foundation

/// P-4 (owner, 19 Oct): "do not interrupt the rider unless absolutely necessary". `LiveAlertKind` / `LiveAlert` (LiveWarnings.swift) are the
/// ONLY things the live ride may raise: the battery 20 / 15 / 10 % voice warnings, the F-22 destination warning and the hot motor.
/// Nothing else may be added to the live view (guard: LiveAlertsTests).

public enum LiveAlerts {
    /// Everything that may interrupt the rider
    public static let interruptions: [LiveAlertKind] = LiveAlertKind.allCases

    /// Plain state banners (not interruptions: the screen is telling the truth about its data)
    public static let statusBanners: Set<LiveBanner> = [.disconnected, .noGps, .phoneBatteryLow]

    /// Whether a banner may be on the live view at all
    public static func isAllowed(_ banner: LiveBanner) -> Bool {
        statusBanners.contains(banner) || interruptions.contains { $0.banners.contains(banner) }
    }

    /// Feeds the banner queue once per update: the status banners and the motor temperature. The only place the live view raises anything.
    public static func feed(_ banners: inout BannerQueue, input: LiveInput, chips: [LiveChip], at t: Double) {
        banners.setActive(.disconnected, input.phoneMode, at: t)
        banners.setActive(.noGps, chips.contains(.noGps) && !input.phoneGpsOff, at: t)
        banners.setActive(.phoneBatteryLow, input.phoneGpsOff, at: t)           // M6-06: phone battery < 10%, GPS off
        if let temp = input.scooterTempC { banners.feedHeat(tempC: temp, at: t) }
    }
}
