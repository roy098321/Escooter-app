import Foundation

/// Hex text <-> bytes, for logs and fixtures ("19 30 00 66", "1930 0066", "19300066").
public enum Hex {
    public static func bytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) })
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    public static func string(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    private static func nibble(_ c: Unicode.Scalar) -> UInt8? {
        switch c.value {
        case 48...57: return UInt8(c.value - 48)        // 0-9
        case 65...70: return UInt8(c.value - 55)        // A-F
        case 97...102: return UInt8(c.value - 87)       // a-f
        default: return nil
        }
    }
}
