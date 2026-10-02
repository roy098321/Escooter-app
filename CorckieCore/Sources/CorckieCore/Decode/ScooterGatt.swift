import Foundation

/// The scooter's Bluetooth services and the read-only rule · ARCHITECTURE §1.4, PROTOCOL.md.
/// ScooterLink may only subscribe to `statusStream` and read Device Information.
/// Everything in `denied` is never touched: no subscribe, no read, no write.
public enum ScooterGatt {
    public static let dataService = "FFF0"
    public static let statusStream = "FFF2"
    public static let deviceInformation = "180A"
    public static let advertisedName = "G2"
    /// "RND" in the manufacturer data
    public static let manufacturerTag: [UInt8] = [0x52, 0x4E, 0x44]

    /// Command and firmware-update services / characteristics: never touched, by design.
    public static let denied: Set<String> = [
        "FFF1",                                    // phone -> scooter commands
        "F000FFC0-0451-4000-B000-000000000000",    // TI OAD service
        "F000FFC1-0451-4000-B000-000000000000",    // TI OAD image identify
        "F000FFC2-0451-4000-B000-000000000000",    // TI OAD image block
        "00010203-0405-0607-0809-0A0B0C0D1912",    // Telink OTA service
        "00010203-0405-0607-0809-0A0B0C0D2B12"     // Telink OTA characteristic
    ]

    /// Upper case; 16-bit UUIDs written in full (0000XXXX-0000-1000-8000-00805F9B34FB) become XXXX.
    public static func normalized(_ uuid: String) -> String {
        let u = uuid.uppercased()
        if u.count == 36, u.hasPrefix("0000"), u.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(u.dropFirst(4).prefix(4))
        }
        return u
    }

    public static func isDenied(_ uuid: String) -> Bool {
        denied.contains(normalized(uuid))
    }

    /// The only characteristic that may be subscribed to.
    public static func maySubscribe(_ uuid: String) -> Bool {
        normalized(uuid) == statusStream
    }

    /// Reading is allowed for Device Information only.
    public static func mayRead(characteristic uuid: String, inService service: String) -> Bool {
        normalized(service) == deviceInformation && !isDenied(uuid)
    }

    /// Is this advertisement our scooter? (name "G2" or "RND" in the manufacturer data)
    public static func isScooter(name: String?, manufacturerData: [UInt8]) -> Bool {
        if name == advertisedName { return true }
        guard manufacturerData.count >= manufacturerTag.count else { return false }
        for start in 0...(manufacturerData.count - manufacturerTag.count)
        where Array(manufacturerData[start..<start + manufacturerTag.count]) == manufacturerTag {
            return true
        }
        return false
    }
}

/// Device Information, read on every connection · CALC_SPEC §1 "Firmware fingerprint".
public struct DeviceInfo: Equatable, Codable, Sendable {
    public var manufacturer: String?
    public var model: String?
    public var firmware: String?
    public var software: String?

    public init(manufacturer: String? = nil, model: String? = nil, firmware: String? = nil, software: String? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.firmware = firmware
        self.software = software
    }

    /// Recorded in P2 (T9): Beken BK-BLE-1.0, firmware 6.1.2, software 6.3.0.
    public static let p2Baseline = DeviceInfo(manufacturer: "BEKEN SAS", model: "BK-BLE-1.0",
                                              firmware: "6.1.2", software: "6.3.0")

    /// Standard Device Information characteristic UUID -> field.
    public mutating func set(characteristic uuid: String, value: String) {
        switch ScooterGatt.normalized(uuid) {
        case "2A29": manufacturer = value
        case "2A24": model = value
        case "2A26": firmware = value
        case "2A28": software = value
        default: break
        }
    }

    public var fingerprint: String {
        "\(model ?? "?") · fw \(firmware ?? "?") · sw \(software ?? "?")"
    }

    /// nil when unchanged (or not fully read yet); else the text for the error log and Scooter tab.
    public func change(from known: DeviceInfo) -> String? {
        guard let fw = firmware, let sw = software else { return nil }
        if fw == known.firmware && sw == known.software && model == known.model { return nil }
        return "Scooter firmware changed (\(known.firmware ?? "?") → \(fw), software \(known.software ?? "?") → \(sw))"
    }
}
