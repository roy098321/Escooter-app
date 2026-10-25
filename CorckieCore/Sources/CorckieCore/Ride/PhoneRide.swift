import Foundation

// MARK: B57 - never lose a ride the phone recorded

/// B57 (owner zip 1.0-264, 19 + 24 Oct): after "Phone took over (formatChanged)" the scooter's odometer and speed froze, so a
/// 1.9 km ride came out as 0 m and was discarded. A ride with real GPS distance is never thrown away after a phone takeover:
/// its distance and top speed come from the GPS, it is kept as "Recorded by phone" with a note.
public enum PhoneRide {
    /// A ride the phone recorded is kept from this much GPS distance on (BUGS B57: "≥ 300 m")
    public static let keepGpsM = 300.0
    /// "Restore discarded ride" offers the discarded pieces of this many days
    public static let restoreDays = 30
    /// The scooter readings were gone for at least this share of the ride: "Recorded by phone"
    public static let recordedByPhoneShare = 0.5

    /// The distance to store: the scooter's (odometer / wheel), or the GPS path when the scooter readings were lost
    /// (format changed, or never came back) and the GPS saw more.
    public static func distanceM(scooterM: Double, gpsM: Double, scooterLost: Bool) -> Double {
        scooterLost ? max(scooterM, gpsM) : scooterM
    }

    /// The size class: the usual M36 one, but a ride the phone took over with ≥ 300 m of GPS is never discarded.
    public static func sizeClass(distanceM: Double, gpsM: Double, phoneTookOver: Bool) -> RideSizeClass {
        let size = RideSizeClass.of(distanceM: distanceM)
        if size == .discarded, phoneTookOver, gpsM >= keepGpsM { return .shortHop }
        return size
    }

    /// Top speed: the scooter's, or the GPS one when the scooter readings were lost (km/h).
    public static func topSpeedKmh(scooterKmh: Double, gpsKmh: Double, scooterLost: Bool) -> Double {
        scooterLost ? max(scooterKmh, gpsKmh) : scooterKmh
    }

    /// "Recorded by phone": the readings went because the format changed, or the scooter was gone for most of the ride.
    public static func recordedByPhone(formatChanged: Bool, scooterGapS: Double, totalS: Double) -> Bool {
        formatChanged || (totalS > 0 && scooterGapS / totalS >= recordedByPhoneShare)
    }

    /// The kind a restored discarded ride gets: its own size class, never "discarded" again (the rider asked to keep it).
    public static func restoredKind(distanceM: Double, gpsM: Double) -> RideSizeClass {
        let size = RideSizeClass.of(distanceM: max(distanceM, gpsM))
        return size == .discarded ? .shortHop : size
    }

    /// Discarded pieces that "Restore discarded ride" offers: real (not simulated), ended, from the last 30 days, newest first.
    public static func restoreCandidates(_ rides: [(id: String, startAt: Int64, kind: String, isSimulated: Bool, ended: Bool)],
                                         nowMs: Int64) -> [String] {
        let from = nowMs - Int64(restoreDays) * 86_400_000
        return rides.filter { $0.kind == RideSizeClass.discarded.rawValue && !$0.isSimulated && $0.ended && $0.startAt >= from }
            .sorted { $0.startAt > $1.startAt }
            .map(\.id)
    }

    /// The line the log gets when the format watch trips: the reason, what the last frame dropped, one raw packet.
    public static func formatChangeLine(reason: String?, dropped: [String], packet: [UInt8]?) -> String {
        var parts = ["Phone took over (formatChanged): " + (reason ?? "reason unknown")]
        parts.append("last frame dropped: " + (dropped.isEmpty ? "nothing" : dropped.joined(separator: ", ")))
        parts.append("packet " + (packet.map { Hex.string($0) } ?? "none"))
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// B57 / notes 10 + 12: what a ride keeps beyond its row's columns (no schema change: one setting row per ride, JSON).
public struct RideExtras: Codable, Equatable, Sendable {
    /// B57: the phone recorded (most of) this ride
    public var recordedByPhone = false
    /// B57: the format watch's reason, and one raw packet (hex) from when it fired
    public var formatReason: String?
    public var formatPacketHex: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case recordedByPhone, formatReason, formatPacketHex }

    /// Every field may be missing (older rows, later fields)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordedByPhone = try c.decodeIfPresent(Bool.self, forKey: .recordedByPhone) ?? false
        formatReason = try c.decodeIfPresent(String.self, forKey: .formatReason)
        formatPacketHex = try c.decodeIfPresent(String.self, forKey: .formatPacketHex)
    }

    public static func key(rideId: String) -> String { "ride.extras." + rideId }

    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func parse(_ text: String?) -> RideExtras {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(RideExtras.self, from: $0) } ?? RideExtras()
    }
}
