import Foundation

// M1-16: the backup rules (DATA_MODEL section 5, M1 plan D1 S123), pure. The app writes the files; this decides
// when, what they are called, what is pruned, what Settings says and when the Home banner shows.

public enum BackupPlan {
    /// A full backup is due when the last one is at least this old (C13 S1)
    public static let fullEveryDays = 7
    /// Home banner after this many days without any backup (C13 S3)
    public static let bannerAfterDays = 14
    /// Full backups kept
    public static let fullsKept = 3
    public static let folderName = "CorckieApp Backup"

    static let dayMs: Int64 = 86_400_000

    /// Never backed up, or the last full is 7 days old or more.
    public static func fullDue(lastFullMs: Int64?, nowMs: Int64) -> Bool {
        guard let last = lastFullMs else { return true }
        return nowMs - last >= Int64(fullEveryDays) * dayMs
    }

    /// The Home banner: rides exist and the last backup (of any kind) is 14 days old or more, or there never was one
    /// and the oldest ride is that old.
    public static func bannerShown(lastBackupMs: Int64?, oldestRideMs: Int64?, nowMs: Int64) -> Bool {
        guard let oldest = oldestRideMs else { return false }
        let reference = lastBackupMs ?? oldest
        return nowMs - reference >= Int64(bannerAfterDays) * dayMs
    }

    public static func bannerText(hasFolder: Bool) -> String {
        hasFolder ? "No backup for 14 days. Check that the backup folder is still reachable, then finish a ride or open Settings."
                  : "Your rides are not backed up. Pick a backup folder in Developer > Backup folder."
    }

    /// "today 18:10" / "yesterday 18:10" / "3 Oct, 18:10" / "never"
    public static func lastBackupText(lastMs: Int64?, nowMs: Int64, utcOffsetMin: Int) -> String {
        guard let last = lastMs else { return "never" }
        let today = RideListLogic.localDay(startAt: nowMs, utcOffsetMin: utcOffsetMin)
        let day = RideListLogic.localDay(startAt: last, utcOffsetMin: utcOffsetMin)
        let time = clock(last, utcOffsetMin)
        if day == today { return "today \(time)" }
        if day == today - 1 { return "yesterday \(time)" }
        let parts = RideListLogic.dayKey(day).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return time }
        return "\(parts[2]) \(RideSummaryBuilder.months[parts[1] - 1]), \(time)"
    }

    static func secondOfDay(_ ms: Int64, _ utcOffsetMin: Int) -> Int {
        let local: Int64 = ms / 1000 + Int64(utcOffsetMin) * 60
        let rem: Int64 = ((local % 86_400) + 86_400) % 86_400
        return Int(rem)
    }

    static func clock(_ ms: Int64, _ utcOffsetMin: Int) -> String {
        let s = secondOfDay(ms, utcOffsetMin)
        return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
    }

    // MARK: File names

    /// full-2026-10-04.corckie
    public static func fullName(atMs ms: Int64, utcOffsetMin: Int) -> String {
        let key = RideListLogic.dayKey(RideListLogic.localDay(startAt: ms, utcOffsetMin: utcOffsetMin))
        return "full-" + key + ".corckie"
    }

    /// rides/2026-10-05_0817_<rideId>.ride (this is the file name; the app puts it in the rides folder)
    public static func rideName(startAtMs ms: Int64, utcOffsetMin: Int, rideId: String) -> String {
        let key = RideListLogic.dayKey(RideListLogic.localDay(startAt: ms, utcOffsetMin: utcOffsetMin))
        let s = secondOfDay(ms, utcOffsetMin)
        let hhmm = String(format: "%02d%02d", s / 3600, (s % 3600) / 60)
        return key + "_" + hhmm + "_" + rideId + ".ride"
    }

    // MARK: Pruning

    /// The date part (yyyy-MM-dd) of a full backup name, nil for other files
    public static func fullDate(_ name: String) -> String? {
        guard name.hasPrefix("full-"), name.hasSuffix(".corckie") else { return nil }
        let key = String(name.dropFirst(5).dropLast(8))
        return key.count == 10 ? key : nil
    }

    /// Full backups beyond the newest `fullsKept`.
    public static func fullsToDelete(_ names: [String]) -> [String] {
        let fulls = names.filter { fullDate($0) != nil }.sorted { (fullDate($0) ?? "") > (fullDate($1) ?? "") }
        return Array(fulls.dropFirst(fullsKept))
    }

    /// Ride deltas dated before the newest full (the full already holds those rides). Same day is kept.
    public static func ridesToDelete(_ rideNames: [String], newestFullDate: String?) -> [String] {
        guard let newest = newestFullDate else { return [] }
        return rideNames.filter { $0.hasSuffix(".ride") && String($0.prefix(10)) < newest }
    }
}

/// Phone battery use over a ride (check q1: at most 10% per 30 min of riding).
public enum PhoneBatteryUse {
    public static let limitPctPer30Min = 10.0
    /// Rides shorter than this are not judged
    public static let minRideS = 900.0

    /// Percent points used per 30 minutes; nil when a reading is missing or the ride is too short.
    public static func per30Min(startPct: Double?, endPct: Double?, rideS: Double) -> Double? {
        guard let a = startPct, let b = endPct, rideS >= minRideS else { return nil }
        return (a - b) / (rideS / 1800)
    }

    public static func withinLimit(_ per30: Double) -> Bool { per30 <= limitPctPer30Min }
}

/// The gzip frame (RFC 1952) around a raw deflate stream, so a `.corckie` / `.ride` file opens in 7-Zip once renamed
/// to `.gz`. The deflate step itself is the app's (Apple's zlib in `NSData.compressed`).
public enum GzipFrame {
    static func makeTable() -> [UInt32] {
        var out: [UInt32] = []
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                if c & 1 != 0 { c = 0xEDB8_8320 ^ (c >> 1) } else { c = c >> 1 }
            }
            out.append(c)
        }
        return out
    }

    static let table: [UInt32] = makeTable()

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            let index = Int((c ^ UInt32(b)) & 0xFF)
            c = table[index] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    /// header + raw deflate + CRC32 + size of the original (both little endian)
    public static func wrap(deflated: [UInt8], original: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        out += deflated
        let crc = crc32(original)
        let size = UInt32(truncatingIfNeeded: original.count)
        for i in 0..<4 { out.append(UInt8((crc >> UInt32(i * 8)) & 0xFF)) }
        for i in 0..<4 { out.append(UInt8((size >> UInt32(i * 8)) & 0xFF)) }
        return out
    }
}
