import Foundation

/// A GPS fix as the core sees it (ARCHITECTURE §2.1). Time in seconds on the caller's clock.
public struct PhoneFix: Equatable, Sendable {
    public var t: Double
    public var lat: Double
    public var lon: Double
    /// Horizontal accuracy, m (negative = invalid)
    public var hAccM: Double
    /// m/s, negative = unknown
    public var speedMps: Double
    /// degrees, negative = unknown
    public var courseDeg: Double
    public var altitudeM: Double?

    public init(t: Double, lat: Double, lon: Double, hAccM: Double, speedMps: Double = -1,
                courseDeg: Double = -1, altitudeM: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.speedMps = speedMps
        self.courseDeg = courseDeg
        self.altitudeM = altitudeM
    }

    /// Good fix: accuracy within T28.
    public var isGood: Bool { hAccM >= 0 && hAccM <= T.t28GoodFixM }
}

/// A barometer reading (relative altitude since the altimeter started).
public struct BaroReading: Equatable, Sendable {
    public var t: Double
    public var relativeAltitudeM: Double
    public var pressureKPa: Double?

    public init(t: Double, relativeAltitudeM: Double, pressureKPa: Double? = nil) {
        self.t = t
        self.relativeAltitudeM = relativeAltitudeM
        self.pressureKPa = pressureKPa
    }
}
