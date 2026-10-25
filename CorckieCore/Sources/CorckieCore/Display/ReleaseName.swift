import Foundation

/// F-30b (owner 21 Oct, FINAL): VB.DDMMYY.HH = version + 2-digit batch . due date DDMMYY . 2-digit hotfix; "101.251026.00".
/// One name everywhere: Settings → About, the build stamp, What's new ("251026"), exports and the report zip, the IPA file name.
/// It is also Apple's CFBundleShortVersionString (the batch number leads, so it always increases); CFBundleVersion stays the CI run.
public enum ReleaseName {
    /// "101.251026.00" is well formed
    public static func isValid(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 3, parts[1].count == 6, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The middle code ("251026"), or the name itself when it is not a release name
    public static func code(_ name: String) -> String {
        isValid(name) ? String(name.split(separator: ".")[1]) : name
    }

    /// "CorckieApp-101.251026.00"
    public static func fileStem(_ name: String) -> String { "CorckieApp-\(name)" }
}
