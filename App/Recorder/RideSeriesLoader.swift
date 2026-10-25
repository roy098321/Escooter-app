import CorckieCore
import Foundation

/// M5-03: everything the full ride detail draws below the numbers, from the stored samples (and the ride's weather rows for Wind).
struct RideSeries {
    var points: [SeriesPoint] = []
    var hills: [LayerSegment] = []
    /// nil = no weather for this ride yet (pattern W)
    var wind: [LayerSegment]?
    var profile: [ElevPoint] = []
    var climbs: [ClimbSpan] = []
    var chart: [SeriesPoint] = []
    var hasAltitude = false
    /// F-04: continuous values per stretch (smoothed ~10 s) for the gradient paths
    var speedValues: [ValueStretch] = []
    var hillValues: [ValueStretch] = []
    var windValues: [ValueStretch]?
    /// F-34: the shared energy track (power shape scaled to the battery drop)
    var energy: EnergyTrack = .empty
    /// F-33: the ride's weather rows (Wind, Wind cost) and its start
    var weather: [WeatherRow] = []
    var rideStartMs: Int64 = 0

    /// F-33: what the layer row draws from
    var layerData: RideLayerData { RideLayerData(points: points, energy: energy, weather: weather, rideStartMs: rideStartMs) }
}

enum RideSeriesLoader {
    static func load(_ db: AppDatabase, rideId: String) -> RideSeries? {
        let q = RideQueries(db)
        guard let ride = try? q.ride(id: rideId), let rows = try? q.samples(rideId: rideId), !rows.isEmpty else { return nil }
        var points: [SeriesPoint] = []
        for s in rows {
            let mps: Double? = s.speedMps ?? s.gpsSpeedMps
            let kmh: Double? = mps.map { $0 * 3.6 }
            points.append(SeriesPoint(t: Double(s.t) / 1000, lat: s.lat, lon: s.lon, hAccM: s.hAccM, speedKmh: kmh,
                                      batteryPct: s.batteryPct, altM: s.altBaroM, powerW: s.powerW, tempC: s.tempC))
        }
        var series = RideSeries()
        series.points = points
        series.rideStartMs = ride.startAt
        series.hasAltitude = points.contains { $0.altM != nil }
        series.hills = RideLayers.hills(points)
        series.speedValues = RideLayers.smoothedStretches(RideLayers.speedStretches(points))
        series.hillValues = RideLayers.smoothedStretches(RideLayers.hillStretches(points))
        let used = CalibrationUpdater.shownUsed(db, rideId: rideId, usedPct: ride.usedPct)
        series.energy = EnergyTrack.build(points, totalUsedPct: used)
        let elevation = RideLayers.elevation(points, energy: series.energy)
        series.profile = elevation.profile
        series.climbs = elevation.climbs
        series.chart = RideLayers.chartSeries(points)
        if let first = points.first(where: { $0.hasFixForLayers }), let lat = first.lat, let lon = first.lon {
            let end = ride.endAt ?? (ride.startAt + Int64((points.last?.t ?? 0) * 1000))
            let weather = FactorUpdater.weatherRows(OutsideQueries(db), cell: GeoCell.key(lat: lat, lon: lon), startMs: ride.startAt, endMs: end)
            series.weather = weather
            series.wind = RideLayers.wind(points, rideStartMs: ride.startAt, rows: weather)
            series.windValues = RideLayers.windStretches(points, rideStartMs: ride.startAt, rows: weather).map { RideLayers.smoothedStretches($0) }
        }
        return series
    }

    /// M37 "To full" on the newest real ride only, hidden once a charge was found after it: "~5 h · from 18:40"
    static func toFull(_ db: AppDatabase, rideId: String) -> String? {
        let rows = (try? CalibrationQueries(db).inputs()) ?? []
        guard let last = rows.first(where: { !$0.isSimulated && $0.kind == "ride" && $0.endAt != nil }), last.id == rideId,
              let endAt = last.endAt, let endPct = last.endRestPct else { return nil }
        let stored = (try? ChargeQueries(db).all()) ?? []
        if stored.contains(where: { $0.afterRideId == rideId }) { return nil }
        let cal = CalibrationUpdater.current(db)
        let hours = ChargeTime.hoursToFull(fromPct: endPct, packAh: cal.packAh, chargerA: BatterySettings.chargerA(db))
        let offset = (try? RideQueries(db).ride(id: rideId))?.utcOffsetMin ?? 0
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: offset * 60)
        f.locale = Locale(identifier: "en_GB")
        let ended = f.string(from: Date(timeIntervalSince1970: Double(endAt) / 1000))
        return "\(ChargeTime.text(hours: hours)) \u{00B7} from \(ended)"
    }
}

extension SeriesPoint {
    /// A good GPS fix (used to pick the ride's weather cell)
    var hasFixForLayers: Bool { lat != nil && lon != nil && (hAccM ?? 0) <= T.t28GoodFixM }
}
