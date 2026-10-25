import Foundation

/// Note 11 (owner 24 Oct, A): the ride review card is draggable like Apple Maps and snaps to four heights: full / default (lower than
/// before, B52: the map keeps ~55 %) / one line ("19 min · 8.0 km · 32 km/h") / hidden (only a small lip at the bottom; a tap on the
/// lip raises the card again). The map, the layer row and the legend stay visible at every height. Partly reverses B29 for this one
/// screen (dilemma D-PR-07). Pure, tested on Linux.

public enum CardDetent: String, CaseIterable, Sendable {
    case full, standard, line, hidden

    /// One step taller / shorter (accessibility adjust, the grabber's tap)
    public var taller: CardDetent {
        switch self { case .hidden: return .line; case .line: return .standard; case .standard, .full: return .full }
    }

    public var shorter: CardDetent {
        switch self { case .full: return .standard; case .standard: return .line; case .line, .hidden: return .hidden }
    }
}

public enum RideCardLayout {
    /// The one-line height: grabber + the line
    public static let lineHeight = 78.0
    /// The lip left at the bottom when hidden
    public static let lipHeight = 34.0
    /// Gap under the layer row / legend at full height
    public static let fullGap = 8.0
    /// The card's top edge overlaps the map's foot by this much at the default height (rounded corners)
    public static let overlap = 20.0

    /// Where the card's top edge sits for each height, in points from the top of the safe area.
    /// `height`: the safe-area height; `topInset`: the status bar; `controlsBottom`: the bottom of the top bar + layer row + legend;
    /// `bottomReserve`: the floating tab bar's room (0 without it).
    public static func top(_ d: CardDetent, height: Double, topInset: Double, controlsBottom: Double, bottomReserve: Double) -> Double {
        let full = controlsBottom + fullGap
        let line = max(full, height - bottomReserve - lineHeight)
        switch d {
        case .full:
            return full
        case .standard:
            let mapFoot = MapScreenLayout.rideMapHeight(screenHeight: height + topInset) - topInset - overlap
            return min(line, max(full, mapFoot))
        case .line:
            return line
        case .hidden:
            return height
        }
    }

    /// The height a drag ends at: the nearest top to where the flick would carry the card
    public static func snap(predictedTop: Double, tops: [CardDetent: Double]) -> CardDetent {
        var best = CardDetent.standard
        var bestDistance = Double.infinity
        for d in CardDetent.allCases {
            guard let t = tops[d] else { continue }
            let distance = abs(t - predictedTop)
            if distance < bestDistance { best = d; bestDistance = distance }
        }
        return best
    }

    /// "19 min · 8.0 km · 32 km/h" (time, distance, top speed); empty parts are left out
    public static func line(time: String, distance: String, topSpeed: String) -> String {
        [time, distance, topSpeed].filter { !$0.isEmpty && $0 != "\u{2013}" }.joined(separator: " \u{00B7} ")
    }

    /// The share of the full-screen map hidden under the card at the default height (for fitting the route above it)
    public static func bottomCover(standardTop: Double, height: Double) -> Double {
        guard height > 0 else { return 0 }
        return max(0, min(0.7, (height - standardTop) / height))
    }
}
