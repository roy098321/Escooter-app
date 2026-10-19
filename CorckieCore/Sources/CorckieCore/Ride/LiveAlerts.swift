import Foundation

/// P-4 (owner, 19 Oct): "do not interrupt the rider unless absolutely necessary". This is the ONE place where the live ride view
/// is allowed to raise something. Today that is only the hot motor (a banner). The next build adds the battery 20 / 15 / 10 %
/// voice warnings and the destination warning here; nothing else may be added to the live view (guard: LiveAlertsTests).
public enum LiveAlert: String, CaseIterable, Sendable {
    case motorHot

    /// The banners this alert may show
    public var banners: Set<LiveBanner> {
        switch self {
        case .motorHot: return [.hot, .veryHot]
        }
    }
}

public enum LiveAlerts {
    /// Everything that may interrupt the rider
    public static let interruptions: [LiveAlert] = LiveAlert.allCases

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
