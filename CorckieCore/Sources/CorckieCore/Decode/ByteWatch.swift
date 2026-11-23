import Foundation

/// B102 (.05): the quiet watch log for the G500 bytes not decoded yet (owner OK 23 Nov). Silent: no UI, no notification.
/// Watched: bytes 8–9 (always 44 so far), 16 (always 1), 17 (always 0), and byte-18 bits other than 0x02 / 0x08 / 0x80.
/// Logged: the first value of each connection, then only a change. Each entry keeps the moment's readings and the raw
/// packet before and after, so a later export shows what the byte follows. Kept: newest 500, at most 60 days.
public struct ByteWatchEntry: Codable, Equatable, Sendable {
    public var atMs: Int64
    public var connection: String
    /// "b8-9", "b16", "b17", "b18-other"
    public var field: String
    public var old: Int?
    public var new: Int
    public var speedKmh: Double
    public var currentA: Double
    public var voltage: Double
    public var temperatureC: Double
    public var status: Int
    public var rawBefore: String?
    public var rawAfter: String
}

public struct ByteWatch: Sendable {
    public static let maxEntries = 500
    public static let maxAgeMs: Int64 = 60 * 24 * 3_600_000
    /// Byte-18 bits already known (motor driven, brake, shutting down)
    public static let knownStatusBits: UInt8 = 0x02 | 0x08 | 0x80

    private var last: [String: Int] = [:]
    private var lastRaw: [UInt8]?
    private var connection = ""

    public init() {}

    /// A new connection: the next packet logs its first values again.
    public mutating func connected(id: String) {
        connection = id
        last = [:]
        lastRaw = nil
    }

    /// The entries this G500 packet makes (empty for any other packet).
    public mutating func observe(_ bytes: [UInt8], atMs: Int64) -> [ByteWatchEntry] {
        guard Decoder.isG500(bytes) else { return [] }
        let p = PacketG500(bytes: bytes)
        let values: [(String, Int)] = [
            ("b8-9", Decoder.le(bytes, 8, 2)),
            ("b16", Int(bytes[16])),
            ("b17", Int(bytes[17])),
            ("b18-other", Int(bytes[18] & ~Self.knownStatusBits)),
        ]
        var out: [ByteWatchEntry] = []
        for (field, value) in values {
            let old = last[field]
            if old == nil || old != value {
                out.append(ByteWatchEntry(atMs: atMs, connection: connection, field: field, old: old, new: value,
                                          speedKmh: p.speedKmh, currentA: p.currentA, voltage: p.voltage,
                                          temperatureC: p.temperatureC, status: Int(p.status),
                                          rawBefore: lastRaw.map { Hex.string($0) }, rawAfter: Hex.string(bytes)))
                last[field] = value
            }
        }
        lastRaw = bytes
        return out
    }

    /// Newest `maxEntries`, none older than `maxAgeMs`.
    public static func trimmed(_ entries: [ByteWatchEntry], nowMs: Int64) -> [ByteWatchEntry] {
        let fresh = entries.filter { nowMs - $0.atMs <= maxAgeMs }
        return Array(fresh.suffix(maxEntries))
    }
}
