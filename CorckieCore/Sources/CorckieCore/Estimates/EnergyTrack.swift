import Foundation

/// F-34 (owner 22 Oct): the shared energy track of one ride. The SHAPE comes from the scooter's power summed per ~100 m of path; it
/// is scaled so the ride's total equals the (flip-filtered, B56) battery drop. A scooter without power readings falls back to the
/// battery % alone; a stretch without readings (the phone took over) is a gap (nil), never a guess.
/// Used by the Battery → Drain and Wind → Wind cost map layers (F-33) and the climbs' battery cost (B38). Steadiness uses speed only;
/// the live gauge and the 20 / 15 / 10 % warnings stay on the filtered gauge %.

/// One ~100 m stretch of the ride.
public struct EnergyBin: Equatable, Sendable {
    public var startDistM: Double
    public var endDistM: Double
    /// seconds from the ride start
    public var startT: Double
    public var endT: Double
    /// Battery points used on this stretch (may be slightly negative downhill); nil = gap, no readings here
    public var usedPct: Double?

    public init(startDistM: Double, endDistM: Double, startT: Double, endT: Double, usedPct: Double?) {
        self.startDistM = startDistM
        self.endDistM = endDistM
        self.startT = startT
        self.endT = endT
        self.usedPct = usedPct
    }

    public var lengthKm: Double { max(0, endDistM - startDistM) / 1_000 }

    /// Battery % per km on this stretch; nil for a gap or a stretch shorter than 20 m
    public var pctPerKm: Double? {
        guard let usedPct, endDistM - startDistM >= 20 else { return nil }
        return usedPct / lengthKm
    }
}

public struct EnergyTrack: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// power shape, scaled to the battery drop
        case power
        /// battery % readings only (a scooter without power readings)
        case battery
        /// nothing to go on
        case none
    }

    public var bins: [EnergyBin]
    public var source: Source
    /// What the bins add up to (the ride's battery drop)
    public var totalUsedPct: Double

    public init(bins: [EnergyBin], source: Source, totalUsedPct: Double) {
        self.bins = bins
        self.source = source
        self.totalUsedPct = totalUsedPct
    }

    public static let empty = EnergyTrack(bins: [], source: .none, totalUsedPct: 0)

    /// Stretch length
    public static let binM = 100.0
    /// A reading gap longer than this does not count as power (the scooter stopped sending)
    public static let maxPowerGapS = 10.0
    /// The power shape is used when at least this share of the readings carries power
    public static let minPowerShare = 0.5

    /// The bin that holds time `t` (seconds from the ride start)
    public func bin(at t: Double) -> EnergyBin? {
        bins.first { t >= $0.startT && t <= $0.endT }
    }

    /// Battery points used between two times: the bins inside, the edge bins pro rata by time. nil when every bin there is a gap.
    public func usedPct(from t0: Double, to t1: Double) -> Double? {
        guard t1 > t0 else { return nil }
        var sum = 0.0
        var any = false
        for b in bins where b.endT > t0 && b.startT < t1 {
            guard let used = b.usedPct else { continue }
            let span = b.endT - b.startT
            let overlap = min(b.endT, t1) - max(b.startT, t0)
            let share = span > 0 ? max(0, min(1, overlap / span)) : 1
            sum += used * share
            any = true
        }
        return any ? sum : nil
    }

    // MARK: Build

    /// The battery drop from the readings: median of the first three minus median of the last three (never below 0).
    public static func batteryDrop(_ points: [SeriesPoint]) -> Double? {
        let readings = points.compactMap(\.batteryPct)
        guard readings.count >= 2 else { return nil }
        func median(_ list: ArraySlice<Int>) -> Int {
            let sorted = list.sorted()
            return sorted[sorted.count / 2]
        }
        let k = max(1, min(3, readings.count / 2))
        return Double(max(0, median(readings.prefix(k)) - median(readings.suffix(k))))
    }

    /// Distance along the ride at each reading: GPS fixes when both ends have a good fix (≤ 30 s apart), else speed × time.
    static func distances(_ points: [SeriesPoint]) -> [Double] {
        var out: [Double] = []
        var dist = 0.0
        var lastFix: (i: Int, p: GeoPoint)?
        for i in points.indices {
            let p = points[i]
            if i > 0 {
                let dt = max(0, p.t - points[i - 1].t)
                if p.hasFix, let g = p.point, let last = lastFix, last.i == i - 1, dt <= 30 {
                    dist += Geo.distanceM(last.p, g)
                } else if let v = p.speedKmh ?? points[i - 1].speedKmh, dt <= 30 {
                    dist += max(0, v) / 3.6 * dt
                }
            }
            if p.hasFix, let g = p.point { lastFix = (i, g) }
            out.append(dist)
        }
        return out
    }

    /// `totalUsedPct`: the ride's battery drop when known (the stored, calibrated number); else it comes from the readings.
    public static func build(_ points: [SeriesPoint], totalUsedPct: Double? = nil, binM: Double = binM) -> EnergyTrack {
        guard points.count >= 2, binM > 0 else { return .empty }
        let dist = distances(points)
        let drop = max(0, totalUsedPct ?? batteryDrop(points) ?? 0)

        // stretches of ~binM: [start index, end index]
        var spans: [(a: Int, b: Int)] = []
        var start = 0
        for i in 1..<points.count where dist[i] - dist[start] >= binM {
            spans.append((start, i))
            start = i
        }
        if start < points.count - 1 { spans.append((start, points.count - 1)) }
        guard !spans.isEmpty else { return .empty }

        let withPower = points.filter { $0.powerW != nil }.count
        let powerShare = Double(withPower) / Double(points.count)
        if powerShare >= minPowerShare, let track = powerTrack(points, dist, spans, drop) { return track }
        if let track = batteryTrack(points, dist, spans, drop) { return track }
        return EnergyTrack(bins: spans.map { EnergyBin(startDistM: dist[$0.a], endDistM: dist[$0.b], startT: points[$0.a].t,
                                                       endT: points[$0.b].t, usedPct: nil) },
                           source: .none, totalUsedPct: 0)
    }

    private static func powerTrack(_ points: [SeriesPoint], _ dist: [Double], _ spans: [(a: Int, b: Int)], _ drop: Double) -> EnergyTrack? {
        var energy: [Double?] = []
        for s in spans {
            var wh = 0.0
            var any = false
            if s.b > s.a {
                for i in (s.a + 1)...s.b {
                    let dt = points[i].t - points[i - 1].t
                    guard dt > 0, dt <= maxPowerGapS, let w = points[i].powerW ?? points[i - 1].powerW else { continue }
                    wh += w * dt / 3_600
                    any = true
                }
            }
            energy.append(any ? wh : nil)
        }
        let total = energy.compactMap { $0 }.reduce(0, +)
        guard total > 0 else { return nil }
        let scale = drop / total
        let bins = spans.indices.map { k in
            EnergyBin(startDistM: dist[spans[k].a], endDistM: dist[spans[k].b], startT: points[spans[k].a].t, endT: points[spans[k].b].t,
                      usedPct: energy[k].map { $0 * scale })
        }
        return EnergyTrack(bins: bins, source: .power, totalUsedPct: drop)
    }

    /// Battery level at a time: whole-percent steps become a line through the moments each new level was first read.
    static func batteryLine(_ points: [SeriesPoint]) -> [(t: Double, pct: Double)] {
        var knots: [(t: Double, pct: Double)] = []
        var last: Int?
        for p in points {
            guard let b = p.batteryPct else { continue }
            if b != last {
                knots.append((p.t, Double(b)))
                last = b
            }
        }
        if let lastReading = points.last(where: { $0.batteryPct != nil }), let k = knots.last, lastReading.t > k.t {
            knots.append((lastReading.t, k.pct))
        }
        return knots
    }

    static func level(_ line: [(t: Double, pct: Double)], at t: Double) -> Double? {
        guard let first = line.first, let last = line.last, t >= first.t, t <= last.t else { return nil }
        for k in 1..<max(1, line.count) where line[k].t >= t {
            let a = line[k - 1], b = line[k]
            let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return a.pct + (b.pct - a.pct) * f
        }
        return last.pct
    }

    private static func batteryTrack(_ points: [SeriesPoint], _ dist: [Double], _ spans: [(a: Int, b: Int)], _ drop: Double) -> EnergyTrack? {
        let line = batteryLine(points)
        guard line.count >= 2 else { return nil }
        var used: [Double?] = []
        for s in spans {
            if let a = level(line, at: points[s.a].t), let b = level(line, at: points[s.b].t) {
                used.append(a - b)
            } else {
                used.append(nil)
            }
        }
        let total = used.compactMap { $0 }.reduce(0, +)
        let scale = total > 0 ? drop / total : 1
        let bins = spans.indices.map { k in
            EnergyBin(startDistM: dist[spans[k].a], endDistM: dist[spans[k].b], startT: points[spans[k].a].t, endT: points[spans[k].b].t,
                      usedPct: used[k].map { $0 * scale })
        }
        return EnergyTrack(bins: bins, source: .battery, totalUsedPct: total > 0 ? drop : total)
    }
}
