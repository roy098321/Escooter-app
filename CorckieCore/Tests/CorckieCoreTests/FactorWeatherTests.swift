import XCTest
@testable import CorckieCore

/// M4-02: a ride's weather columns (M16 headwind, T70 wind level, M17 wet) and day columns (M18 rush hour, M19 day type,
/// holiday week) from made-up rows (a point in the ocean) and the 2026 offline holiday calendar.
final class FactorWeatherTests: XCTestCase {
    private let hour = OutsideTime.hourMs
    private let h0: Int64 = 1_786_510_800_000 - 5 * 3_600_000 + 10 * 3_600_000   // 2026-08-12 10:00 UTC

    private func row(_ at: Int64, wind: Double, from: Double?, precip: Double = 0, temp: Double = 28) -> WeatherRow {
        WeatherRow(cellKey: "1000,-3000", hourAt: at, source: "test", kind: .history, windKmh: wind, windFromDeg: from, precipMm: precip,
                   airTempC: temp, fetchedAt: 0)
    }

    /// 10 min at 20 km/h on a straight line, a fix every second (bearing in degrees)
    private func straight(bearing: Double, seconds: Int = 600) -> [FactorFix] {
        let v = 20 / 3.6
        let mPerDeg = Double.pi * Geo.earthRadiusM / 180
        let lat0 = 10.0, lon0 = -30.0
        return (0...seconds).map { s in
            let d = v * Double(s)
            let north = d * cos(bearing * Double.pi / 180), east = d * sin(bearing * Double.pi / 180)
            return FactorFix(t: Int64(s) * 1000, lat: lat0 + north / mPerDeg, lon: lon0 + east / (mPerDeg * cos(lat0 * Double.pi / 180)), hAccM: 5)
        }
    }

    // MARK: M16 headwind

    func test_headwind_againstAlongAndAcross() throws {
        let start = h0 + 10 * 60_000
        func hw(windFrom: Double, bearing: Double) -> Double? {
            RideWeatherCalc.headwind(fixes: straight(bearing: bearing), rideStartMs: start, rows: [row(h0, wind: 20, from: windFrom), row(h0 + hour, wind: 20, from: windFrom)])
        }
        XCTAssertEqual(try XCTUnwrap(hw(windFrom: 0, bearing: 0)), 20, accuracy: 0.3)      // riding north into a north wind
        XCTAssertEqual(try XCTUnwrap(hw(windFrom: 180, bearing: 0)), -20, accuracy: 0.3)   // tailwind
        XCTAssertEqual(try XCTUnwrap(hw(windFrom: 90, bearing: 0)), 0, accuracy: 0.3)      // crosswind
        XCTAssertEqual(try XCTUnwrap(hw(windFrom: 270, bearing: 225)), 20 * cos(45 * Double.pi / 180), accuracy: 0.3)
    }

    func test_headwind_outAndBack_isDistanceWeighted() throws {
        let start = h0 + 10 * 60_000
        let out = straight(bearing: 0, seconds: 300)
        let last = try XCTUnwrap(out.last)
        let mPerDeg = Double.pi * Geo.earthRadiusM / 180
        // back south over half the distance
        let back = (1...150).map { s in FactorFix(t: last.t + Int64(s) * 1000, lat: last.lat - 20 / 3.6 * Double(s) / mPerDeg, lon: last.lon, hAccM: 5) }
        let v = try XCTUnwrap(RideWeatherCalc.headwind(fixes: out + back, rideStartMs: start, rows: [row(h0, wind: 18, from: 0), row(h0 + hour, wind: 18, from: 0)]))
        XCTAssertEqual(v, 18 * (2.0 / 3) - 18 * (1.0 / 3), accuracy: 0.4)
    }

    func test_headwind_noGps_orNoWeather_isNil() {
        let start = h0 + 10 * 60_000
        let rows = [row(h0, wind: 20, from: 0), row(h0 + hour, wind: 20, from: 0)]
        XCTAssertNil(RideWeatherCalc.headwind(fixes: [], rideStartMs: start, rows: rows))
        XCTAssertNil(RideWeatherCalc.headwind(fixes: straight(bearing: 0, seconds: 20), rideStartMs: start, rows: rows), "under 300 m with a course")
        XCTAssertNil(RideWeatherCalc.headwind(fixes: straight(bearing: 0), rideStartMs: start, rows: []))
        // bad fixes (> 20 m accuracy) are not used
        let bad = straight(bearing: 0).map { f -> FactorFix in var b = f; b.hAccM = 65; return b }
        XCTAssertNil(RideWeatherCalc.headwind(fixes: bad, rideStartMs: start, rows: rows))
        // the whole ride: pattern W, nothing crashes
        let w = RideWeatherCalc.ride(startMs: start, endMs: start + 600_000, fixes: straight(bearing: 0), rows: [])
        XCTAssertTrue(w.isMissing)
        XCTAssertNil(w.headwindKmh)
        XCTAssertNil(w.wet)
    }

    func test_interpolation_linearSpeed_circularDirection() throws {
        let rows = [row(h0, wind: 10, from: 350, temp: 20), row(h0 + hour, wind: 20, from: 10, temp: 30)]
        let mid = try XCTUnwrap(RideWeatherCalc.at(rows, atMs: h0 + hour / 2))
        XCTAssertEqual(mid.windKmh, 15, accuracy: 1e-9)
        let dir = try XCTUnwrap(mid.windFromDeg)
        XCTAssertEqual(min(dir, 360 - dir), 0, accuracy: 1e-6, "350 and 10 meet at north, not at 180")
        XCTAssertEqual(try XCTUnwrap(mid.airTempC), 25, accuracy: 1e-9)
        let q = try XCTUnwrap(RideWeatherCalc.at(rows, atMs: h0 + hour / 4))
        XCTAssertEqual(try XCTUnwrap(q.windFromDeg), 355, accuracy: 1e-6)
        // past the last row by more than an hour: nothing
        XCTAssertNil(RideWeatherCalc.at(rows, atMs: h0 + 3 * hour))
        XCTAssertNotNil(RideWeatherCalc.at(rows, atMs: h0 + hour + hour / 2))
    }

    func test_windLevels_T70() {
        XCTAssertEqual(RideWeatherCalc.windLevel(14.9), "light")
        XCTAssertEqual(RideWeatherCalc.windLevel(15), "moderate")
        XCTAssertEqual(RideWeatherCalc.windLevel(30), "moderate")
        XCTAssertEqual(RideWeatherCalc.windLevel(30.1), "strong")
    }

    func test_ride_fillsAllColumns() throws {
        let start = h0 + 10 * 60_000
        let rows = [row(h0, wind: 24, from: 0, temp: 30), row(h0 + hour, wind: 24, from: 0, temp: 32)]
        let w = RideWeatherCalc.ride(startMs: start, endMs: start + 600_000, fixes: straight(bearing: 0), rows: rows)
        XCTAssertEqual(try XCTUnwrap(w.headwindKmh), 24, accuracy: 0.4)
        XCTAssertEqual(w.windLevel, "moderate")
        XCTAssertEqual(w.wet, "dry")
        XCTAssertEqual(try XCTUnwrap(w.airTempC), 30.5, accuracy: 0.05)
        XCTAssertFalse(w.isMissing)
    }

    // MARK: M17 wet

    func test_wet_duringTheRide_lightAndHeavy() {
        let s = h0 + 15 * 60_000, e = h0 + 45 * 60_000
        XCTAssertEqual(RideWeatherCalc.wet(startMs: s, endMs: e, rows: [row(h0 + hour, wind: 5, from: 0, precip: 0.5)]), "light")
        XCTAssertEqual(RideWeatherCalc.wet(startMs: s, endMs: e, rows: [row(h0 + hour, wind: 5, from: 0, precip: 3)]), "heavy")
        XCTAssertEqual(RideWeatherCalc.wet(startMs: s, endMs: e, rows: [row(h0 + hour, wind: 5, from: 0, precip: 0.1)]), "dry")
        XCTAssertNil(RideWeatherCalc.wet(startMs: s, endMs: e, rows: []), "the ride's own hour is missing: pattern W")
    }

    func test_wet_windowBeforeTheRide_T71() {
        // 1 mm fell in the hour to 10:00: window 1 h + 0.5 h
        let rain = row(h0, wind: 5, from: 0, precip: 1)
        func ride(startAfterRain minutes: Int64) -> String? {
            let s = h0 + minutes * 60_000
            var rows = [rain]
            var h = OutsideTime.floorHour(s) + hour
            while h <= OutsideTime.floorHour(s + 20 * 60_000) + hour {
                rows.append(row(h, wind: 5, from: 0))
                h += hour
            }
            return RideWeatherCalc.wet(startMs: s, endMs: s + 20 * 60_000, rows: rows)
        }
        XCTAssertEqual(ride(startAfterRain: 30), "light")
        XCTAssertEqual(ride(startAfterRain: 85), "light")
        XCTAssertEqual(ride(startAfterRain: 100), "dry")
        // 8 mm: window 1 + 4 h, capped at 4 h; 2.5 h after the rain still wet, and heavy (4 mm in an hour)
        let heavyRain = [row(h0 - hour, wind: 5, from: 0, precip: 4), row(h0, wind: 5, from: 0, precip: 4)]
        let s = h0 + 2 * hour + 30 * 60_000
        let rows = heavyRain + [row(h0 + 3 * hour, wind: 5, from: 0)]
        XCTAssertEqual(RideWeatherCalc.wet(startMs: s, endMs: s + 20 * 60_000, rows: rows), "heavy")
    }

    func test_wetOverride_wins() {
        XCTAssertEqual(RideWeatherCalc.applyOverride("dry", override: "wet"), "light")
        XCTAssertEqual(RideWeatherCalc.applyOverride("heavy", override: "wet"), "heavy")
        XCTAssertEqual(RideWeatherCalc.applyOverride("heavy", override: "dry"), "dry")
        XCTAssertNil(RideWeatherCalc.applyOverride(nil, override: nil))
    }

    func test_merge_historyBeatsForecast() {
        let f = [row(h0, wind: 10, from: 0), row(h0 + hour, wind: 11, from: 0)]
        var h = row(h0, wind: 30, from: 90)
        h.kind = .history
        let m = RideWeatherCalc.merge(history: [h], forecast: f)
        XCTAssertEqual(m.map(\.windKmh), [30, 11])
    }

    // MARK: M18 / M19 day type, rush hour, holiday week (2026, offline calendar = Hebcal for days off and eves)

    func test_dayType_holidays2026() {
        let days = OfflineHolidays.holidays(year: 2026)
        let ist = 180
        // Mon 21 Sep 2026 08:00 = Yom Kippur: Saturday, no rush hour
        let yk = DayContextCalc.context(startAtMs: 1_789_966_800_000, utcOffsetMin: ist, holidays: days)
        XCTAssertEqual(yk.dayType, "saturday")
        XCTAssertFalse(yk.rushHour)
        XCTAssertTrue(yk.holidayWeek)
        XCTAssertEqual(yk.localDate, "2026-09-21")
        // Sun 20 Sep 08:00 = Erev Yom Kippur: Friday
        let eve = DayContextCalc.context(startAtMs: 1_789_880_400_000, utcOffsetMin: ist, holidays: days)
        XCTAssertEqual(eve.dayType, "friday")
        XCTAssertFalse(eve.rushHour)
        // Wed 23 Sep 08:00: a workday in a holiday week, rush hour
        let wed = DayContextCalc.context(startAtMs: 1_790_139_600_000, utcOffsetMin: ist, holidays: days)
        XCTAssertEqual(wed.dayType, "workday")
        XCTAssertTrue(wed.rushHour)
        XCTAssertTrue(wed.holidayWeek)
        // Wed 12 Aug 08:00: plain workday, rush hour, no holiday week; Fri 14 Aug is a Friday
        let aug = DayContextCalc.context(startAtMs: 1_786_510_800_000, utcOffsetMin: ist, holidays: days)
        XCTAssertEqual(aug.dayType, "workday")
        XCTAssertTrue(aug.rushHour)
        XCTAssertFalse(aug.holidayWeek)
        XCTAssertEqual(DayContextCalc.context(startAtMs: 1_786_683_600_000, utcOffsetMin: ist, holidays: days).dayType, "friday")
        // 12:00 is not rush hour
        XCTAssertFalse(DayContextCalc.context(startAtMs: 1_786_510_800_000 + 4 * hour, utcOffsetMin: ist, holidays: days).rushHour)
    }

    func test_dayType_choleHamoedIsAWorkday() {
        // Chol Hamoed (a Hebcal "holiday" row) is a working day; only isDayOff counts
        let ch = Holiday(date: "2026-08-12", name: "Sukkot III (CH''M)", kind: .holiday)
        let c = DayContextCalc.context(startAtMs: 1_786_510_800_000, utcOffsetMin: 180, holidays: [ch])
        XCTAssertEqual(c.dayType, "workday")
        XCTAssertFalse(c.holidayWeek)
    }

    func test_years_crossNewYear() {
        // 30 Dec 2026 12:00 UTC: its week reaches into 2027
        XCTAssertEqual(DayContextCalc.years(startAtMs: 1_798_632_000_000, utcOffsetMin: 120), [2026, 2027])
    }
}
