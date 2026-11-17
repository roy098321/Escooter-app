import ActivityKit
import Foundation

/// N7-1 (batch 7): the scooter's Live Activity / Dynamic Island, one card that follows the scooter: Ready (on connect: km left,
/// the likely destination, battery on arrival, Start ride / Change; gone after ~2 min without a ride), Riding (a quiet
/// "● Recording 12:34"; grey with "GPS lost"), Arrived (the summary with End ride / Keep going; the ride still ends by itself).
/// Charging stays the charge Live Activity (F-31), now with "Enough for <place> by HH:MM". NO alerts during a ride (P-4).
/// Local updates only. Foundation + ActivityKit only (compiled into the app and the widget extension).
struct ScooterActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case ready, riding, arrived
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Ready: "≈ 24 km left"
        var kmLeft: Int?
        /// Ready / Arrived: the destination's name
        var destination: String?
        /// Ready: the battery on arrival there
        var arrivalPct: Int?
        /// Riding: when recording started (the clock ticks by itself)
        var recordingSince: Date?
        /// Riding: tracking dropped
        var gpsLost = false
        /// Arrived: "4.2 km · 13 min · ₪3.10 saved"
        var summary: String?
    }

    var name: String
}
