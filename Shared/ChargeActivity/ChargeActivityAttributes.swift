import ActivityKit
import Foundation

/// F-31: the Live Activity of a charge (compiled into the app and the widget extension; Foundation + ActivityKit only).
/// Local updates only, no push server. The bar and the clock tick by themselves from the dates, so a stale update never shows a wrong time.
struct ChargeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Where the 13.6 %/h line crosses 0 % and 100 %: the % at any moment is the share of this span that has passed
        var zeroAt: Date
        var fullAt: Date
    }

    var name: String
    var pluggedAt: Date
}
