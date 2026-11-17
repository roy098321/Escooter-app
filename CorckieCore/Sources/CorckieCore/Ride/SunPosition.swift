import Foundation

/// N8-1 (batch 8): the sun's elevation, computed offline (NOAA's simplified solar position, about ±0.5° — plenty for "is it dark").
/// "Dark" = civil dusk: the sun more than 6° below the horizon.
public enum SunPosition {
    public static let civilDuskDeg = -6.0

    /// Elevation in degrees at `epochS` (UTC seconds) for a place
    public static func elevationDeg(lat: Double, lon: Double, epochS: Double) -> Double {
        let rad = Double.pi / 180
        let jd = epochS / 86_400 + 2_440_587.5
        let n = jd - 2_451_545.0
        let l = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let lambda = (l + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let epsilon = (23.439 - 0.0000004 * n) * rad
        let decl = asin(sin(epsilon) * sin(lambda))
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let gmst = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        let hourAngle = (gmst * 15 + lon) * rad - ra
        let phi = lat * rad
        let sinAlt = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hourAngle)
        return asin(max(-1, min(1, sinAlt))) / rad
    }

    public static func isDark(lat: Double, lon: Double, epochS: Double) -> Bool {
        elevationDeg(lat: lat, lon: lon, epochS: epochS) < civilDuskDeg
    }

    /// N8-1 "Dark before you arrive": light now, dark at the arrival (with a destination) or within 15 min (without one)
    public static func darkBeforeArrival(lat: Double, lon: Double, nowS: Double, remainingS: Double?) -> Bool {
        guard !isDark(lat: lat, lon: lon, epochS: nowS) else { return false }
        return isDark(lat: lat, lon: lon, epochS: nowS + (remainingS ?? 15 * 60))
    }
}
