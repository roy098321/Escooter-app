import Foundation

/// M4-02: a ride's day columns (`dayType`, `rushHour`, `holidayWeek`) from its own start time and UTC offset and the
/// holiday list (M4-01). M19: Sun-Thu workday, Fri Friday, Sat Saturday; a day-off holiday (`Holiday.isDayOff`) counts as
/// Saturday, its eve (`isEveOfDayOff`) as Friday. Only that classification is used: Hebcal also lists Chol Hamoed,
/// Hanukkah, Purim... which are working days. M18: rush hour only on a workday (T72).
public struct DayContext: Equatable, Sendable {
    /// workday / friday / saturday
    public var dayType: String
    public var rushHour: Bool
    /// The ride's week (Sunday to Saturday, local) has a day-off holiday
    public var holidayWeek: Bool
    /// yyyy-MM-dd, local
    public var localDate: String

    public init(dayType: String, rushHour: Bool, holidayWeek: Bool, localDate: String) {
        self.dayType = dayType
        self.rushHour = rushHour
        self.holidayWeek = holidayWeek
        self.localDate = localDate
    }
}

public enum DayContextCalc {
    public static func localDate(startAtMs: Int64, utcOffsetMin: Int) -> String {
        OutsideTime.day(startAtMs + Int64(utcOffsetMin) * 60_000)
    }

    /// The years whose holidays a ride needs (its own, and the next / previous one when its week crosses New Year).
    public static func years(startAtMs: Int64, utcOffsetMin: Int) -> [Int] {
        let local = startAtMs + Int64(utcOffsetMin) * 60_000
        let a = Int(OutsideTime.day(local - 7 * OutsideTime.dayMs).prefix(4)) ?? 0
        let b = Int(OutsideTime.day(local + 7 * OutsideTime.dayMs).prefix(4)) ?? 0
        return Array(Set([a, b])).sorted()
    }

    public static func context(startAtMs: Int64, utcOffsetMin: Int, holidays: [Holiday]) -> DayContext {
        let weekday = DayClock.weekday(startAtMs: startAtMs, utcOffsetMin: utcOffsetMin)
        let minute = DayClock.minuteOfDay(startAtMs: startAtMs, utcOffsetMin: utcOffsetMin)
        let date = localDate(startAtMs: startAtMs, utcOffsetMin: utcOffsetMin)
        let daysOff = Set(holidays.filter { $0.isDayOff }.map(\.date))
        let eves = Set(holidays.filter { $0.isEveOfDayOff }.map(\.date))
        var type = DayClock.dayType(weekday: weekday)
        if daysOff.contains(date) {
            type = "saturday"
        } else if type == "workday", eves.contains(date) {
            type = "friday"
        }
        let rush = type == "workday" && DayClock.isRushHour(weekday: weekday, minuteOfDay: minute)
        // the week: Sunday (weekday 0) to Saturday
        let local = startAtMs + Int64(utcOffsetMin) * 60_000
        var holidayWeek = false
        for d in 0..<7 {
            let day = OutsideTime.day(local + Int64(d - weekday) * OutsideTime.dayMs)
            if daysOff.contains(day) { holidayWeek = true }
        }
        return DayContext(dayType: type, rushHour: rush, holidayWeek: holidayWeek, localDate: date)
    }
}
