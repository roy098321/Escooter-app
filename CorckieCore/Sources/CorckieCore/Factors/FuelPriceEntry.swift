import Foundation

/// B75 (batch 3): fuel prices always look like D.DD (e.g. 8.27 ₪/L), so the rider types 3 digits and the point goes in by itself.
/// 8 → "8", 82 → "8.2", 827 → "8.27". Anything else typed or pasted is reduced to its first 3 digits ("8.27" → "8.27").
public enum FuelPriceEntry {
    public static let digits = 3

    /// What the field shows for whatever was typed or pasted
    public static func format(_ input: String) -> String {
        let d = String(input.filter(\.isASCIIDigitChar).prefix(digits))
        guard d.count > 1 else { return d }
        return String(d.prefix(1)) + "." + String(d.dropFirst())
    }

    /// The price, only once all 3 digits are in (and above 0)
    public static func value(_ text: String) -> Double? {
        let d = text.filter(\.isASCIIDigitChar)
        guard d.count == digits, let n = Int(d), n > 0 else { return nil }
        return Double(n) / 100
    }
}

private extension Character {
    var isASCIIDigitChar: Bool { ("0"..."9").contains(self) }
}
