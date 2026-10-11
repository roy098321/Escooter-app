import CorckieCore
import Foundation

/// M5-04: a stored ride as Ride Replay data (the page's 1 Hz timeline), plus its title, its day and the file name.
struct ReplayRide {
    var data: ReplayData
    var fileName: String
}

enum ReplayDataLoader {
    /// The stored readings of a ride as replay / export rows (seconds from the ride start)
    static func readings(_ db: AppDatabase, rideId: String) -> (ride: RideRecord, rows: [ReplayRow])? {
        let q = RideQueries(db)
        guard let ride = try? q.ride(id: rideId), let samples = try? q.samples(rideId: rideId), samples.count >= 2 else { return nil }
        var rows: [ReplayRow] = []
        rows.reserveCapacity(samples.count)
        for s in samples {
            let speed: Double? = s.speedMps.map { $0 * 3.6 }
            let gps: Double? = s.gpsSpeedMps.map { $0 * 3.6 }
            let pct: Double? = s.batteryPct.map { Double($0) }
            rows.append(ReplayRow(t: Double(s.t) / 1000, lat: s.lat, lon: s.lon, hAccM: s.hAccM, speedKmh: speed, gpsKmh: gps,
                                  altM: s.altBaroM, powerW: s.powerW, batteryPct: pct, tempC: s.tempC))
        }
        return (ride, rows)
    }

    static func load(_ db: AppDatabase, rideId: String) -> ReplayRide? {
        guard let (ride, rows) = readings(db, rideId: rideId) else { return nil }
        let q = RideQueries(db)
        let stopRows = (try? q.stops(rideId: rideId)) ?? []
        var stops: [(startS: Double, endS: Double)] = []
        for s in stopRows {
            stops.append((startS: Double(s.startT) / 1000, endS: Double(s.endT ?? s.startT) / 1000))
        }
        let info = ReplayRideInfo(distanceM: ride.distanceM, avgMovingMps: ride.avgMovingMps, topSpeedMps: ride.topSpeedMps,
                                  startPct: ride.startRestPct, endPct: ride.endRestPct, energyWh: ride.energyWhRaw,
                                  elevGainM: ride.elevGainM, elevLossM: ride.elevLossM, tempPeakC: ride.tempPeakC, stops: ride.stops)
        let offset = ride.utcOffsetMin ?? 0
        let title = RideSummaryBuilder.title(startAt: ride.startAt, utcOffsetMin: offset)
        guard let data = ReplayBuilder.make(title: title, dateLabel: dayLabel(ride.startAt, offset), startAtMs: ride.startAt, utcOffsetMin: offset,
                                            rows: rows, stops: stops, info: info) else { return nil }
        return ReplayRide(data: data, fileName: ReplayHTML.fileName(title: title, isoDate: isoDay(ride.startAt, offset)))
    }

    static func isoDay(_ startAt: Int64, _ offsetMin: Int) -> String {
        RideQueries.dayKey(startAt: startAt, utcOffsetMin: offsetMin)
    }

    /// "6 Oct"
    static func dayLabel(_ startAt: Int64, _ offsetMin: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(secondsFromGMT: offsetMin * 60)
        f.dateFormat = "d MMM"
        return f.string(from: Date(timeIntervalSince1970: Double(startAt) / 1000))
    }

    /// Made-up ride for the u39 check and the ui-shot (in the ocean, never a real place)
    static func sample(seconds: Int = 300) -> ReplayData? {
        var rows: [ReplayRow] = []
        var t = 0
        while t <= seconds {
            let s = Double(t)
            let lat: Double = 10 + s * 0.000_04 + 0.0006 * sin(s / 25)
            let lon: Double = -30 + s * 0.000_05
            let speed: Double = 14 + 12 * abs(sin(s / 40))
            let alt: Double = 30 + 8 * sin(s / 60)
            let battery: Double = 81 - Double(t / 120)
            rows.append(ReplayRow(t: s, lat: lat, lon: lon, hAccM: 5, speedKmh: speed, gpsKmh: speed - 1, altM: alt, powerW: 180 + 60 * sin(s / 15),
                                  batteryPct: battery, tempC: 30 + s / 40))
            t += 5
        }
        return ReplayBuilder.make(title: "Sample ride", dateLabel: "6 Oct", startAtMs: 1_790_000_000_000, utcOffsetMin: 180, rows: rows,
                                  stops: [(startS: 120, endS: 140)], info: ReplayRideInfo(distanceM: 1_800, startPct: 81, endPct: 79, energyWh: 14))
    }
}
