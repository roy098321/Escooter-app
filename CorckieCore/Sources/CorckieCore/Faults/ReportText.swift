import Foundation

// N10-14 / N10-15 (batch 10): the two report languages the rider picks when exporting (English / עברית). Hebrew is right-to-left;
// numbers and units stay left-to-right. One font (Arial). Never places, routes, times of day or the rider's name.

public enum ReportLanguage: String, CaseIterable, Sendable {
    case english, hebrew
    public var rightToLeft: Bool { self == .hebrew }
}

public enum ReportText {
    public enum Key: String, CaseIterable, Sendable {
        case historyTitle, scooter, odometer, trackedSince, reportDate, batteryHealth, onFullCharge, logged, found, dealtWith, open,
             date, km, what, source, outcome, measured, entered, outcomeOpen, checkedFine, fixed, transparency, trackingStarted,
             mechanicTitle, notADiagnosis, page
    }

    public static func t(_ k: Key, _ lang: ReportLanguage) -> String {
        switch lang {
        case .english: return english[k] ?? k.rawValue
        case .hebrew: return hebrew[k] ?? english[k] ?? k.rawValue
        }
    }

    static let english: [Key: String] = [
        .historyTitle: "Maintenance history", .scooter: "Scooter", .odometer: "Odometer", .trackedSince: "Tracked since",
        .reportDate: "Report date", .batteryHealth: "Battery health", .onFullCharge: "on a full charge", .logged: "logged",
        .found: "found", .dealtWith: "dealt with", .open: "open", .date: "Date", .km: "km", .what: "What", .source: "Source",
        .outcome: "Outcome", .measured: "Measured", .entered: "Entered", .outcomeOpen: "Open", .checkedFine: "Checked fine",
        .fixed: "Fixed",
        .transparency: "Measured = the app saw it in the scooter's own data. Entered = the owner logged it. No places, routes or times of day are included.",
        .trackingStarted: "Tracking started", .mechanicTitle: "Report for a mechanic",
        .notADiagnosis: "What the app measured. Not a diagnosis.", .page: "Page",
    ]

    static let hebrew: [Key: String] = [
        .historyTitle: "היסטוריית תחזוקה", .scooter: "קורקינט", .odometer: "מד מרחק", .trackedSince: "במעקב מאז",
        .reportDate: "תאריך הדוח", .batteryHealth: "בריאות הסוללה", .onFullCharge: "בטעינה מלאה", .logged: "נרשמו",
        .found: "התגלו", .dealtWith: "טופלו", .open: "פתוחות", .date: "תאריך", .km: "ק״מ", .what: "מה", .source: "מקור",
        .outcome: "תוצאה", .measured: "נמדד", .entered: "הוזן", .outcomeOpen: "פתוח", .checkedFine: "נבדק, תקין", .fixed: "תוקן",
        .transparency: "נמדד = האפליקציה ראתה זאת בנתוני הקורקינט עצמו. הוזן = הבעלים רשם זאת. ללא מקומות, מסלולים או שעות.",
        .trackingStarted: "תחילת מעקב", .mechanicTitle: "דוח למכונאי",
        .notADiagnosis: "מה שהאפליקציה מדדה. לא אבחנה.", .page: "עמוד",
    ]

    public static func faultTitle(_ k: FaultKind, _ lang: ReportLanguage) -> String {
        guard lang == .hebrew else { return MaintHistory.title(k) }
        switch k {
        case .f1Sag: return "הסוללה מתאמצת תחת עומס"
        case .f2PowerCut: return "ניתוק חשמל בזמן רכיבה"
        case .f3BrakeCut: return "הבלמים לא מנתקים את המנוע"
        case .f5Tyre: return "צמיג רך או שחוק"
        case .f6Heat: return "המנוע התחמם"
        case .f7Sensor: return "קריאות חיישן בלתי אפשריות"
        case .f11ParkedDrain: return "הסוללה התרוקנה בחניה"
        case .f12FullVoltage: return "המטען לא ממלא את הסוללה"
        case .f16OdoReset: return "מד הק״מ אופס"
        }
    }

    public static func logTitle(_ w: LogWhatIDid, _ lang: ReportLanguage) -> String {
        guard lang == .hebrew else { return w.title }
        switch w {
        case .tyrePressure: return "נבדק לחץ צמיגים"
        case .replacedTyre: return "הוחלף צמיג"
        case .brakesAdjusted: return "נבדקו או כוונו בלמים"
        case .replacedPads: return "הוחלפו רפידות בלם"
        case .boltsTightened: return "הודקו ברגים ומנגנון קיפול"
        case .replacedBattery: return "הוחלפה הסוללה"
        case .replacedCharger: return "הוחלף המטען"
        case .motorServiced: return "טיפול במנוע"
        case .wiringRepaired: return "תוקנו חיווט או מחברים"
        }
    }

    /// One history row's title in the chosen language
    public static func entryTitle(_ e: HistoryEntry, logged: [LoggedWork], faults: [FaultRecord], _ lang: ReportLanguage) -> String {
        if e.id == "tracking-started" { return t(.trackingStarted, lang) }
        if let w = logged.first(where: { $0.id == e.id }) { return logTitle(w.what, lang) }
        if let f = faults.first(where: { $0.id == e.id }) { return faultTitle(f.kind, lang) }
        return e.title
    }

    public static func outcome(_ o: HistoryEntry.Outcome, _ lang: ReportLanguage) -> String {
        switch o {
        case .open: return t(.outcomeOpen, lang)
        case .checkedFine: return t(.checkedFine, lang)
        case .fixed: return t(.fixed, lang)
        }
    }
}

// MARK: N10-15 mechanic report words

public enum MechanicText {
    public enum Key: String, CaseIterable, Sendable {
        case theScooter, theIssue, occurrences, normalVsNow, history, cantSee, rawData, workshop, firmware, confirmedOn, times,
             firstSeen, lastSeen, trend, worse, steady, better, minutesIn, speed, current, voltage, motorTemp, air, braking, yes, no,
             found, whatToDo, leadsLater, cantSeeText, rawDataText, workshopLine, normalLine, now, otherFaults, none, loggedWork,
             reportDate, appVersion, model
    }

    public static func t(_ k: Key, _ lang: ReportLanguage) -> String {
        (lang == .hebrew ? hebrew[k] : nil) ?? english[k] ?? k.rawValue
    }

    static let english: [Key: String] = [
        .theScooter: "The scooter", .theIssue: "The issue", .occurrences: "When it happens", .normalVsNow: "Your normal vs now",
        .history: "History", .cantSee: "What the app can't see", .rawData: "Raw data", .workshop: "Workshop result",
        .firmware: "Firmware", .confirmedOn: "Confirmed on", .times: "times", .firstSeen: "First seen", .lastSeen: "Last seen",
        .trend: "Trend", .worse: "getting worse", .steady: "steady", .better: "getting better", .minutesIn: "Min into ride",
        .speed: "Speed km/h", .current: "Current A", .voltage: "Voltage V", .motorTemp: "Motor °C", .air: "Air °C",
        .braking: "Braking", .yes: "yes", .no: "no", .found: "What was found", .whatToDo: "What to do first",
        .leadsLater: "Leads for the workshop are added once a mechanic has checked them.",
        .cantSeeText: "No fault codes, no throttle position, one temperature (motor or controller, not both); the battery % is the scooter's rough estimate.",
        .rawDataText: "Every reading around each occurrence is in the CSV file sent with this report.",
        .workshopLine: "Found: ____________   Done: ____________   km: ________",
        .normalLine: "Your normal line", .now: "Now", .otherFaults: "Other faults", .none: "none", .loggedWork: "Work logged",
        .reportDate: "Report date", .appVersion: "App version", .model: "Model",
    ]

    static let hebrew: [Key: String] = [
        .theScooter: "הקורקינט", .theIssue: "התקלה", .occurrences: "מתי זה קורה", .normalVsNow: "הרגיל שלך מול עכשיו",
        .history: "היסטוריה", .cantSee: "מה האפליקציה לא רואה", .rawData: "נתונים גולמיים", .workshop: "תוצאת המוסך",
        .firmware: "קושחה", .confirmedOn: "אושר ב", .times: "פעמים", .firstSeen: "נראה לראשונה", .lastSeen: "נראה לאחרונה",
        .trend: "מגמה", .worse: "מחמיר", .steady: "יציב", .better: "משתפר", .minutesIn: "דקות ברכיבה",
        .speed: "מהירות קמ״ש", .current: "זרם A", .voltage: "מתח V", .motorTemp: "מנוע °C", .air: "אוויר °C",
        .braking: "בלימה", .yes: "כן", .no: "לא", .found: "מה נמצא", .whatToDo: "מה לבדוק קודם",
        .leadsLater: "כיווני בדיקה למוסך יתווספו אחרי שמכונאי יבדוק אותם.",
        .cantSeeText: "אין קודי תקלה, אין מצב מצערת, טמפרטורה אחת (מנוע או בקר, לא שתיהן); אחוז הסוללה הוא הערכה גסה של הקורקינט.",
        .rawDataText: "כל הקריאות סביב כל מקרה נמצאות בקובץ ה-CSV שנשלח עם הדוח.",
        .workshopLine: "נמצא: ____________   בוצע: ____________   ק״מ: ________",
        .normalLine: "הקו הרגיל שלך", .now: "עכשיו", .otherFaults: "תקלות אחרות", .none: "אין", .loggedWork: "עבודות שנרשמו",
        .reportDate: "תאריך הדוח", .appVersion: "גרסת האפליקציה", .model: "דגם",
    ]

    public static func found(_ k: FaultKind, _ lang: ReportLanguage) -> String {
        guard lang == .hebrew else { return FaultCopy.text(k).found }
        switch k {
        case .f1Sag: return "מתח הסוללה יורד יותר לכל אמפר מהרגיל שלך, ב-3 רכיבות במזג אוויר דומה."
        case .f2PowerCut: return "הקורקינט כיבה את עצמו בזמן רכיבה מעל 10 קמ״ש."
        case .f3BrakeCut: return "המנוע המשיך לדחוף 3 שניות או יותר בזמן שהבלם היה לחוץ."
        case .f5Tyre: return "ב-10 הרכיבות האחרונות באותו מסלול, הגלגל סופר מרחק שונה מה-GPS ממה שספר בעבר."
        case .f6Heat: return "המנוע היה חם ב-10°C או יותר ממה שצריך ב-3 הרכיבות האחרונות, בהשוואה לרכיבות באותו מאמץ ומזג אוויר."
        case .f7Sensor: return "אות הטמפרטורה או מהירות הגלגל קפץ או נעלם בצורה שחיישן תקין לא יכול, ב-2 רכיבות."
        case .f11ParkedDrain: return "מתח המנוחה ירד יותר מהרגיל של הקורקינט הזה בזמן חניה, ב-3 חניות."
        case .f12FullVoltage: return "אחרי 3 הטעינות האחרונות הסוללה נחה הרבה מתחת למתח המלא הרגיל שלך."
        case .f16OdoReset: return "מד הק״מ של הקורקינט חזר אחורה או לאפס."
        }
    }

    public static func what(_ k: FaultKind, _ lang: ReportLanguage) -> String {
        guard lang == .hebrew else { return FaultCopy.text(k).what }
        switch k {
        case .f1Sag: return "לבדוק את תקע הסוללה והמחברים."
        case .f2PowerCut: return "לבדוק את תקע הסוללה. אם זה חוזר, לבדוק את הסוללה."
        case .f3BrakeCut: return "לבדוק את מתג הבלם ואת הבקר."
        case .f5Tyre: return "לבדוק לחץ אוויר בצמיג ואת החריצים."
        case .f6Heat: return "לבדוק את המנוע אצל מכונאי."
        case .f7Sensor: return "לבדוק את כבל המנוע ואת המחבר שלו."
        case .f11ParkedDrain: return "לבדוק את הסוללה לתא חלש."
        case .f12FullVoltage: return "למדוד את מתח היציאה של המטען."
        case .f16OdoReset: return "אין צורך לעשות דבר. התזכורות מתחילות מהמספר החדש."
        }
    }

    /// The fault's number with its unit, for "Your normal vs now"
    public static func unit(_ k: FaultKind) -> String {
        switch k {
        case .f1Sag: return "mΩ"
        case .f5Tyre: return "%"
        case .f6Heat: return "°C"
        case .f11ParkedDrain: return "V/day"
        case .f12FullVoltage: return "V"
        default: return ""
        }
    }

    /// Getting worse / steady / better over the occurrences (oldest first): last third vs first third, 10 % step
    public static func trend(_ values: [Double], higherIsWorse: Bool) -> Int {
        guard values.count >= 3 else { return 0 }
        let n = max(1, values.count / 3)
        let a = values.prefix(n).reduce(0, +) / Double(n), b = values.suffix(n).reduce(0, +) / Double(n)
        let step = max(abs(a) * 0.1, 1e-9)
        if abs(b - a) < step { return 0 }
        return (b > a) == higherIsWorse ? 1 : -1
    }
}
