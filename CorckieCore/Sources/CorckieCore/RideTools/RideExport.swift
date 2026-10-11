import Foundation

/// M5-05: one ride as CSV and GPX (CONCEPT "Exports"). Times are ISO 8601 local time with the offset (S4), CSV is UTF-8 with decimal points,
/// GPX speed and power come from the scooter and the positions from the phone's GPS (S5). Pure text, tested on Linux.
public enum RideExport {
    /// "2026-10-06T08:10:05+03:00" for an instant in epoch ms at a UTC offset
    public static func iso(ms: Int64, utcOffsetMin: Int) -> String {
        let local = Int64(Double(ms) / 1000) + Int64(utcOffsetMin) * 60
        let days = Int((Double(local) / 86_400).rounded(.down))
        let secs = Int(local - Int64(days) * 86_400)
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        let off = abs(utcOffsetMin)
        let sign = utcOffsetMin < 0 ? "-" : "+"
        let date = String(format: "%04d-%02d-%02d", year, m, d)
        let time = String(format: "%02d:%02d:%02d", secs / 3_600, secs % 3_600 / 60, secs % 60)
        let zone = String(format: "%02d:%02d", off / 60, off % 60)
        return date + "T" + time + sign + zone
    }

    private static func num(_ v: Double?, _ decimals: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(decimals)f", v)
    }

    public static let csvHeader = "time,seconds,speed_kmh,gps_speed_kmh,latitude,longitude,altitude_m,power_w,battery_pct,temp_c"

    public static func csv(rows: [ReplayRow], startAtMs: Int64, utcOffsetMin: Int) -> String {
        var out = csvHeader + "\n"
        for r in rows.sorted(by: { $0.t < $1.t }) {
            let at = startAtMs + Int64((r.t * 1000).rounded())
            let fields: [String] = [iso(ms: at, utcOffsetMin: utcOffsetMin), num(r.t, 1), num(r.speedKmh, 1), num(r.gpsKmh, 1), num(r.lat, 6),
                                    num(r.lon, 6), num(r.altM, 1), num(r.powerW, 0), num(r.batteryPct, 0), num(r.tempC, 1)]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A track with time and elevation, plus the scooter's speed (m/s) and power as extensions. Fixes without a good position are left out.
    public static func gpx(name: String, rows: [ReplayRow], startAtMs: Int64, utcOffsetMin: Int) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"CorckieApp\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        out += "<trk><name>\(escapeXML(name))</name><trkseg>\n"
        for r in rows.sorted(by: { $0.t < $1.t }) {
            guard let lat = r.lat, let lon = r.lon, (r.hAccM ?? 0) <= T.t28GoodFixM else { continue }
            let at = startAtMs + Int64((r.t * 1000).rounded())
            out += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\">", lat, lon)
            if let e = r.altM { out += String(format: "<ele>%.1f</ele>", e) }
            out += "<time>\(iso(ms: at, utcOffsetMin: utcOffsetMin))</time>"
            var ext = ""
            if let v = r.speedKmh { ext += String(format: "<speed>%.2f</speed>", v / 3.6) }
            if let p = r.powerW { ext += String(format: "<power>%.0f</power>", p) }
            if !ext.isEmpty { out += "<extensions>\(ext)</extensions>" }
            out += "</trkpt>\n"
        }
        out += "</trkseg></trk>\n</gpx>\n"
        return out
    }
}
