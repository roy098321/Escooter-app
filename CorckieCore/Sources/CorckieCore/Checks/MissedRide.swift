import Foundation

/// B81 (hotfix 103.081126.02): "Ride not recorded" and "Export log". Pure parts, testable on Linux:
/// - the diary line format (one event per line, kept 30 days on the phone)
/// - the report's time window ("When did you ride?")
/// - the one-line cause the app gives when it can tell
/// - how long each log is kept (owner, 9 Nov)
/// - which detail the 5 MB export drops first (oldest first; per ride its raw packets, then its samples)

/// One diary event: "<epoch ms>\t<kind>\t<text>" (kinds: app, bluetooth, ride, phone, log, voice, notification, report)
public struct DiaryLine: Equatable, Sendable {
    public var atMs: Int64
    public var kind: String
    public var text: String

    public init(atMs: Int64, kind: String, text: String) {
        self.atMs = atMs
        self.kind = kind
        self.text = text
    }

    public var encoded: String {
        "\(atMs)\t\(kind)\t" + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    public static func parse(_ line: String) -> DiaryLine? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let ms = Int64(parts[0]) else { return nil }
        return DiaryLine(atMs: ms, kind: String(parts[1]), text: String(parts[2]))
    }
}

/// Owner, 9 Nov: logs are kept for a while, then cleaned once a day; data (rides, places, charges, settings) is not a log and stays
public enum LogRetention {
    public static let diaryDays = 30
    public static let errorLogDays = 30
    public static let messageLogDays = 90
    public static let reportDays = 30

    public static func cutoffMs(nowMs: Int64, days: Int) -> Int64 { nowMs - Int64(days) * 86_400_000 }
}

/// "When did you ride?"
public enum MissedRideWhen: String, CaseIterable, Codable, Sendable {
    case justNow, earlierToday, yesterday

    public var label: String {
        switch self {
        case .justNow: return "Just now"
        case .earlierToday: return "Earlier today"
        case .yesterday: return "Yesterday"
        }
    }

    /// The window the report covers: 2 h back for Just now; else about an hour before and after the rough start time
    public static func window(_ when: MissedRideWhen, nowMs: Int64, roughStartMs: Int64?) -> ClosedRange<Int64> {
        let hour: Int64 = 3_600_000
        switch when {
        case .justNow:
            return (nowMs - 2 * hour)...nowMs
        case .earlierToday, .yesterday:
            let start = roughStartMs ?? nowMs - (when == .yesterday ? 24 : 3) * hour
            return (start - hour)...min(nowMs, start + 2 * hour)
        }
    }
}

/// A ride row in the window (kind "discarded" = left out of the Rides list)
public struct MissedRideRow: Equatable, Sendable {
    public var startAt: Int64
    public var kind: String
    public var distanceM: Double?

    public init(startAt: Int64, kind: String, distanceM: Double?) {
        self.startAt = startAt
        self.kind = kind
        self.distanceM = distanceM
    }
}

public enum MissedRideGuess {
    /// The one line the app shows after "Save report" when it can tell the cause (nil = it can't; the report goes with the export)
    public static func cause(lines all: [DiaryLine], rides: [MissedRideRow], window: ClosedRange<Int64>,
                             locationAlways: Bool, utcOffsetMin: Int) -> String? {
        let lines = all.filter { window.contains($0.atMs) }
        func clock(_ ms: Int64) -> String {
            let m = Int(((ms / 60_000) + Int64(utcOffsetMin)) % 1440 + 1440) % 1440
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        // 1. a ride was recorded after all
        if let r = rides.filter({ window.contains($0.startAt) && $0.kind != "discarded" }).first {
            let km = r.distanceM.map { String(format: " (%.1f km)", $0 / 1000) } ?? ""
            return "A ride was recorded at \(clock(r.startAt))\(km). It is in the Rides list."
        }
        // 2. a ride started and was dropped
        if let d = lines.first(where: { $0.kind == "ride" && $0.text.contains("dropped (") }) {
            let raw = d.text.components(separatedBy: "dropped (").last?.components(separatedBy: ")").first ?? ""
            return "A ride started at \(clock(d.atMs)) but was dropped: \(dropReason(raw))."
        }
        // 3. location not Always: no background recording
        if !locationAlways {
            return "Location is set to While Using, so the app can't record in the background. Settings \u{2192} CorckieApp \u{2192} Location \u{2192} Always."
        }
        // 4. the app did not run at all
        if !lines.contains(where: { $0.kind == "app" || $0.kind == "bluetooth" || $0.kind == "ride" }) {
            return "The app wasn't running then: iOS didn't wake it for the scooter."
        }
        let connected = lines.contains { $0.kind == "bluetooth" && $0.text.hasPrefix("Connected") }
        let started = lines.contains { $0.kind == "ride" && $0.text.contains("started") }
        // 5. never connected / connected but no ride
        if !connected { return "The app was running but never connected to the scooter." }
        if !started { return "The scooter connected, but no ride started." }
        return nil
    }

    public static func dropReason(_ raw: String) -> String {
        switch raw {
        case "gpsStill": return "the wheel turned but the GPS stayed still"
        case "unconfirmed": return "it was never confirmed as riding"
        case "noRiding": return "no real riding was seen"
        case "notRiding": return "Not riding was tapped"
        case "scooterOff": return "the scooter switched off before the ride was confirmed"
        case "disconnected": return "the scooter disconnected before the ride was confirmed"
        default: return raw.isEmpty ? "reason unknown" : raw
        }
    }
}

/// The 5 MB cap of Export log: which detail files go first
public enum ExportCap {
    public static let capBytes = 5 * 1_024 * 1_024

    public struct DetailFile: Equatable, Sendable {
        public enum Kind: Int, Sendable { case raw = 0, samples = 1 }
        public var name: String
        /// The ride's start (or the file's date), epoch ms: oldest goes first
        public var atMs: Int64
        public var kind: Kind
        public var bytes: Int

        public init(name: String, atMs: Int64, kind: Kind, bytes: Int) {
            self.name = name
            self.atMs = atMs
            self.kind = kind
            self.bytes = bytes
        }
    }

    /// Oldest ride first; per ride its raw packets before its samples
    public static func dropOrder(_ files: [DetailFile]) -> [DetailFile] {
        files.sorted { a, b in a.atMs != b.atMs ? a.atMs < b.atMs : a.kind.rawValue < b.kind.rawValue }
    }

    /// The files to drop so a zip of `zipBytes` (from `rawBytes` before zipping) fits under the cap; +10 % margin (G2)
    public static func toDrop(_ files: [DetailFile], zipBytes: Int, rawBytes: Int, cap: Int = capBytes) -> [DetailFile] {
        guard zipBytes > cap, rawBytes > 0 else { return [] }
        let ratio = Double(zipBytes) / Double(rawBytes)
        let needRaw = Double(zipBytes - cap) / max(ratio, 0.01) * 1.10
        var out: [DetailFile] = []
        var freed = 0.0
        for f in dropOrder(files) where freed < needRaw {
            out.append(f)
            freed += Double(f.bytes)
        }
        return out
    }
}
