import Foundation

/// B72 (hotfix 04, owner 2 Nov): after "Unplugged" the Scooter tab kept "≈ 84 % estimate when unplugged" while Home said "Last reading
/// 47 %": the real reading only replaced the estimate while a charge timer ran. Now a real reading after the unplug moment ends the
/// estimate whether a timer runs or not, and the Scooter tab shows the estimate only while it is newer than Home's last reading
/// (LastReading.pick): one source. Pure, tested on Linux.
public enum UnpluggedEstimate {
    /// What the readings since the unplug moment do to the estimate
    public enum Action: Equatable, Sendable {
        /// no real reading yet
        case keep
        /// a reading that says nothing about the charge (none rested before a ride): only the estimate goes
        case clear
        /// the first rested reading after the unplug: the estimate goes and the unplugged charge's log entry gets this real end %
        case clearAndComplete(Double)
    }

    /// - connectedPct: the settled % of a connected scooter now; riding: a ride is on (its % carries the load: not used for the charge)
    /// - rideSince: the newest finished ride that started after the unplug moment, with its rested start % (the reading at that
    ///   connection, before any riding)
    public static func settle(unpluggedMs: Int64, connectedPct: Int?, riding: Bool,
                              rideSince: (startMs: Int64, startRestPct: Double?)?) -> Action {
        if let r = rideSince, r.startMs > unpluggedMs { return r.startRestPct.map { .clearAndComplete($0) } ?? .clear }
        if let p = connectedPct, !riding { return .clearAndComplete(Double(p)) }
        return .keep
    }

    /// The Scooter tab shows the estimate only while it is newer than the last real reading (else the same reading as Home)
    public static func shows(unpluggedMs: Int64, lastReadingMs: Int64?) -> Bool {
        guard let last = lastReadingMs else { return true }
        return unpluggedMs > last
    }

    /// The newest entry, when it is the unplugged (estimated) one, gets the real end %
    public static func complete(_ log: [ChargeLogEntry], realPct: Double) -> [ChargeLogEntry] {
        guard let first = log.first, !first.measured else { return log }
        var out = log
        out[0] = first.withRealEnd(realPct)
        return out
    }
}
