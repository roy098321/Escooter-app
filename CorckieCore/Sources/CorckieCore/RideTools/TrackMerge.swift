import Foundation

/// Hotfix .13 (owner 25 Nov): the ride map cut corners at speed (5-s samples are ~100 m apart at 70 km/h). Rides recorded from .13 keep
/// the phone's GPS once a second (`RecorderTrack`); this puts those fixes between the stored samples. Each added point takes the
/// position from the fix and the readings (speed, height, power, temperature) interpolated from the samples around it, so every
/// layer draws along the road and time-weighted sums (energy, At top speed) are unchanged. Pure, so it is tested on Linux.
public enum TrackMerge {
    /// Samples further apart than this are a gap: the fix keeps its position but no readings are made up across it
    public static let maxSampleGapS = 30.0
    /// A fix this close to a sample adds nothing
    public static let nearSampleS = 0.5

    public static func merge(_ points: [SeriesPoint], track: [(t: Double, lat: Double, lon: Double, hAccM: Double)]) -> [SeriesPoint] {
        guard let first = points.first?.t, let last = points.last?.t, !track.isEmpty else { return points }
        var out: [SeriesPoint] = []
        out.reserveCapacity(points.count + track.count)
        var k = 0
        let fixes = track.filter { $0.t > first && $0.t < last }.sorted { $0.t < $1.t }
        for i in points.indices {
            out.append(points[i])
            guard i + 1 < points.count else { break }
            let a = points[i], b = points[i + 1]
            while k < fixes.count, fixes[k].t <= a.t { k += 1 }
            while k < fixes.count, fixes[k].t < b.t {
                let f = fixes[k]
                k += 1
                if f.t - a.t < nearSampleS || b.t - f.t < nearSampleS { continue }
                let span = b.t - a.t
                let inGap = span > maxSampleGapS
                let w = (f.t - a.t) / span
                func mix(_ x: Double?, _ y: Double?) -> Double? {
                    guard !inGap, let x, let y else { return nil }
                    return x + (y - x) * w
                }
                out.append(SeriesPoint(t: f.t, lat: f.lat, lon: f.lon, hAccM: f.hAccM, speedKmh: mix(a.speedKmh, b.speedKmh),
                                       batteryPct: inGap ? nil : a.batteryPct, altM: mix(a.altM, b.altM), powerW: mix(a.powerW, b.powerW),
                                       tempC: mix(a.tempC, b.tempC)))
            }
        }
        return out
    }
}
