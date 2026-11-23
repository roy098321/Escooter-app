import Foundation

/// F-32 (policy P-5, owner 20 Oct): after every update, one card over the dimmed Home lists what changed: ✕ top right (a tap outside
/// also closes it), never during a ride (it waits for the next launch), once per build. The content comes from the bundled
/// `WhatsNew.json`; every build must add its entry (a Linux test checks the newest entry is this build's version). The card shows only
/// the middle code of the version name ("What's new · 251026", F-30b point 6). Settings → What's new keeps every build's list.

public struct WhatsNewItem: Codable, Equatable, Sendable {
    /// SF Symbol
    public var symbol: String
    public var title: String
    public var line: String
}

public struct WhatsNewEntry: Codable, Equatable, Sendable {
    /// The full release name, "101.251026.00" (F-30b)
    public var version: String
    public var headline: String
    /// 3–4 items on the card
    public var items: [WhatsNewItem]
    /// "+ 22 smaller fixes"
    public var smallerFixes: Int
    /// Every change, one plain line each (Settings → What's new)
    public var full: [String]
    /// N11-4: an optional hero line above the title ("Bug #100 fixed 🎉 Thanks for every report."). Batch 12 (N12-1) removes it.
    public var hero: String? = nil
    /// N11-4: a one-time confetti burst behind the card on this version (once, ~2 s, no sound; none with Reduce Motion)
    public var confetti: Bool? = nil

    /// "251026": the middle of "101.251026.00"
    public var code: String { ReleaseName.code(version) }

    public var title: String { "What's new \u{00B7} \(code)" }

    public var smallerFixesLine: String? { smallerFixes > 0 ? "+ \(smallerFixes) smaller change\(smallerFixes == 1 ? "" : "s")" : nil }
}

public enum WhatsNew {
    /// Newest first
    public static func decode(_ data: Data) throws -> [WhatsNewEntry] { try JSONDecoder().decode([WhatsNewEntry].self, from: data) }

    /// The card shows on the first launch of a new build, not during a ride, once
    public static func shouldShow(current: String, lastSeen: String?, riding: Bool, entries: [WhatsNewEntry]) -> Bool {
        guard !riding, lastSeen != current else { return false }
        return entries.contains { $0.version == current }
    }

    /// N11-4: confetti only for an entry that asks for it, once per version, never with Reduce Motion (the hero line still shows)
    public static func showConfetti(_ entry: WhatsNewEntry, reduceMotion: Bool, alreadyShown: Bool) -> Bool {
        entry.confetti == true && !reduceMotion && !alreadyShown
    }

    /// N11-4: the burst lasts about two seconds
    public static let confettiSeconds: Double = 2

    /// N11-4: the per-version flag ("corckie.whatsNew.confetti.111.291126.00")
    public static func confettiKey(_ version: String) -> String { "corckie.whatsNew.confetti.\(version)" }

    public static func entry(for version: String, in entries: [WhatsNewEntry]) -> WhatsNewEntry? {
        entries.first { $0.version == version }
    }
}
