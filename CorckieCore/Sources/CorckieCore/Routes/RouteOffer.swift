import Foundation

/// M2-01: what the ride summary says about the ride's route: the "Save as route?" card after the same trip twice (T63),
/// or a plain "Route · Home → Work" line once saved. Texts are made here so they are tested (no rewards, P-3: no
/// streaks, no "personal best").
public struct RouteOfferModel: Equatable, Sendable {
    public var routeId: String
    /// true = already saved (no buttons)
    public var saved: Bool
    public var headline: String
    public var detail: String

    /// nil for a dismissed route (never shown again)
    public static func make(routeId: String, state: RouteState, title: String, ridesOnRoute: Int) -> RouteOfferModel? {
        switch state {
        case .dismissed:
            return nil
        case .saved:
            return RouteOfferModel(routeId: routeId, saved: true, headline: "Route \u{00B7} \(title)",
                                   detail: "This ride is one of \(ridesOnRoute) on this route.")
        case .suggested:
            let times = ridesOnRoute <= 2 ? "twice" : "\(ridesOnRoute) times"
            return RouteOfferModel(routeId: routeId, saved: false, headline: "Save as route?",
                                   detail: "You have ridden this same trip \(times). Save it to see your usual time and today's estimate.")
        }
    }
}
