import Foundation

/// M18 / M19 / T72: weekday, rush hour and day type from a ride's own start time and UTC offset (DST-safe: the offset is the
/// one stored with the ride). No time zone database, no `Calendar`.
public enum DayClock {
    /// 0 = Sunday … 6 = Saturday
    public static func weekday(startAtMs: Int64, utcOffsetMin: Int) -> Int {
        let local = startAtMs / 1000 + Int64(utcOffsetMin) * 60
        let days = Int((Double(local) / 86_400).rounded(.down))
        return ((days + 4) % 7 + 7) % 7        // 1970-01-01 was a Thursday
    }

    public static func minuteOfDay(startAtMs: Int64, utcOffsetMin: Int) -> Int {
        let local = startAtMs / 1000 + Int64(utcOffsetMin) * 60
        let secOfDay = ((local % 86_400) + 86_400) % 86_400
        return Int(secOfDay / 60)
    }

    /// M19: Sun-Thu workday, Fri Friday, Sat Saturday (holidays come with the holiday table in M4)
    public static func isWorkday(weekday: Int) -> Bool { weekday >= 0 && weekday <= 4 }

    /// M18: starts 07:00-09:30 or 16:00-19:00 on a workday (T72)
    public static func isRushHour(weekday: Int, minuteOfDay: Int) -> Bool {
        guard isWorkday(weekday: weekday) else { return false }
        return (minuteOfDay >= 7 * 60 && minuteOfDay <= 9 * 60 + 30) || (minuteOfDay >= 16 * 60 && minuteOfDay <= 19 * 60)
    }

    public static func isRushHour(startAtMs: Int64, utcOffsetMin: Int) -> Bool {
        isRushHour(weekday: weekday(startAtMs: startAtMs, utcOffsetMin: utcOffsetMin),
                   minuteOfDay: minuteOfDay(startAtMs: startAtMs, utcOffsetMin: utcOffsetMin))
    }

    /// "workday" / "friday" / "saturday"
    public static func dayType(weekday: Int) -> String {
        if isWorkday(weekday: weekday) { return "workday" }
        return weekday == 5 ? "friday" : "saturday"
    }

    /// "8:56"
    public static func clockText(minuteOfDay: Int) -> String {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

/// T101 / policy P-1: anything the app acts on uses the estimate + 10%; the number shown stays the honest estimate.
public enum SafetyMargin {
    public static let factor = 1.0 + T.t101SafetyMarginShare

    /// What a decision uses (greying, there-and-back, the ride-start warning)
    public static func forDecision(_ estimate: Double) -> Double { estimate * factor }
}
