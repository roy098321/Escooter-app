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
