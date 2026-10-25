import Foundation

/// B29 (owner, 19 Oct): ride detail, route card and the place screen are a map of FIXED height on top and a normal scroll view
/// below (no draggable sheet, no detents). This is the one number that layout needs, kept here so it is unit tested.
public enum MapScreenLayout {
    /// The map's share of the screen height
    public static let share = 0.40
    public static let minMapHeight = 280.0
    public static let maxMapHeight = 400.0
    /// The scroll area below the map never gets smaller than this (small phones, big text)
    public static let minScrollHeight = 300.0

    /// B52 (owner 21 Oct): the ride summary / ride detail map takes ~55 % of the screen (the whole route visible), the six tiles and
    /// More sit in the lower part: no empty bottom half
    public static let rideShare = 0.55
    public static let rideMaxMapHeight = 620.0

    /// Height of the map from the very top of the screen (status bar included)
    public static func mapHeight(screenHeight: Double, share: Double = share, maxHeight: Double = maxMapHeight) -> Double {
        let wanted = min(max(screenHeight * share, minMapHeight), maxHeight)
        return max(120, min(wanted, screenHeight - minScrollHeight))
    }

    /// B52: the ride review's map height
    public static func rideMapHeight(screenHeight: Double) -> Double {
        mapHeight(screenHeight: screenHeight, share: rideShare, maxHeight: rideMaxMapHeight)
    }
}
