import Foundation

/// The offline fallback for Hebcal (ARCHITECTURE section 3): the day-off holidays and their eves from Foundation's
/// Hebrew calendar. Names follow Hebcal's, so the two sources agree. Only what M19 needs: days off and eves
/// (Chol Hamoed and the minor days are not listed offline). Independence Day shifts: 5 Iyar on a Friday or Saturday
/// moves back to the Thursday, on a Monday forward to the Tuesday; Memorial Day is the day before.
public enum OfflineHolidays {
    /// Hebrew month in Foundation's numbering: Tishri 1, Nisan 8, Iyar 9, Sivan 10 (Adar I only exists in leap years).
    private static let fixed: [(month: Int, day: Int, name: String, eve: String?)] = [
        (1, 1, "Rosh Hashana", "Erev Rosh Hashana"),
        (1, 2, "Rosh Hashana II", nil),
        (1, 10, "Yom Kippur", "Erev Yom Kippur"),
        (1, 15, "Sukkot I", "Erev Sukkot"),
        (1, 22, "Shmini Atzeret", nil),
        (8, 15, "Pesach I", "Erev Pesach"),
        (8, 21, "Pesach VII", nil),
        (10, 6, "Shavuot", "Erev Shavuot")
    ]

    public static func holidays(year: Int) -> [Holiday] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = utc.timeZone
        guard let start = utc.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = utc.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
        func text(_ d: Date) -> String {
            let c = utc.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        var out: [Holiday] = []
        var day = start
        while day < end {
            let h = hebrew.dateComponents([.month, .day], from: day)
            let previous = utc.date(byAdding: .day, value: -1, to: day) ?? day
            if let month = h.month, let dom = h.day {
                for item in fixed where item.month == month && item.day == dom {
                    out.append(Holiday(date: text(day), name: item.name, kind: .holiday))
                    if let eve = item.eve { out.append(Holiday(date: text(previous), name: eve, kind: .eve)) }
                }
                if month == 9 && dom == 5 {
                    let weekday = utc.component(.weekday, from: day)   // 1 = Sunday ... 6 = Friday, 7 = Saturday
                    let shift = weekday == 6 ? -1 : (weekday == 7 ? -2 : (weekday == 2 ? 1 : 0))
                    if let independence = utc.date(byAdding: .day, value: shift, to: day),
                       let memorial = utc.date(byAdding: .day, value: -1, to: independence) {
                        out.append(Holiday(date: text(memorial), name: "Yom HaZikaron", kind: .holiday))
                        out.append(Holiday(date: text(independence), name: "Yom HaAtzma\u{2019}ut", kind: .holiday))
                    }
                }
            }
            guard let next = utc.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        // an eve on 1 Jan or a shifted day can fall outside the year: keep only this year's dates
        return out.filter { $0.date.hasPrefix("\(year)-") }.sorted { ($0.date, $0.name) < ($1.date, $1.name) }
    }
}

extension Holiday {
    /// Name without the year number and the Chol Hamoed tag, curly apostrophes made plain:
    /// "Rosh Hashana 5787" -> "Rosh Hashana", "Pesach II (CH''M)" -> "Pesach II".
    var baseName: String {
        var n = name.replacingOccurrences(of: "\u{2019}", with: "'")
        if let paren = n.range(of: " (") { n = String(n[n.startIndex..<paren.lowerBound]) }
        let words = n.split(separator: " ")
        if let last = words.last, last.count == 4, last.allSatisfy({ $0.isNumber }) { n = words.dropLast().joined(separator: " ") }
        return n
    }

    /// M19: a day off (counts as Saturday). Chol Hamoed days and minor days (Hanukkah, Purim, Family Day...) are not.
    public var isDayOff: Bool {
        guard kind == .holiday else { return false }
        return ["Rosh Hashana", "Rosh Hashana II", "Yom Kippur", "Sukkot I", "Shmini Atzeret", "Pesach I", "Pesach VII", "Shavuot",
                "Yom HaAtzma'ut"].contains(baseName)
    }

    /// M19: the eve of a day off (counts as Friday).
    public var isEveOfDayOff: Bool {
        guard kind == .eve else { return false }
        return ["Erev Rosh Hashana", "Erev Yom Kippur", "Erev Sukkot", "Erev Pesach", "Erev Shavuot"].contains(baseName)
    }
}
