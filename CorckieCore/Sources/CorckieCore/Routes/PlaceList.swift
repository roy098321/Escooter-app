import Foundation

/// M2-05: the Places screen (rename, adjust the circle, "I can charge here"). Texts are made here so they are tested.
public struct PlaceRowModel: Equatable, Sendable {
    public var id: String
    /// The place's name, or "Unnamed place"
    public var title: String
    /// "Circle: automatic . 2 routes"
    public var subtitle: String
    public var canCharge: Bool
    /// nil = automatic (5% of the trip, T60)
    public var radiusM: Double?
    public var hasName: Bool
}

public enum PlaceListBuilder {
    /// Circle sizes the owner can pick (metres); nil = automatic
    public static let radiusChoices: [Double] = [100, 200, 300, 500, 1_000]

    public static func radiusText(_ radiusM: Double?) -> String {
        guard let r = radiusM else { return "Circle: automatic" }
        return "Circle: \(Int(r.rounded())) m"
    }

    public static func row(id: String, name: String?, radiusM: Double?, canCharge: Bool, routeCount: Int) -> PlaceRowModel {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = [radiusText(radiusM)]
        if canCharge { parts.append("you can charge here") }
        parts.append("\(routeCount) \(routeCount == 1 ? "route" : "routes")")
        return PlaceRowModel(id: id, title: trimmed.isEmpty ? RouteLabels.place(nil) : trimmed,
                             subtitle: parts.joined(separator: " \u{00B7} "), canCharge: canCharge, radiusM: radiusM, hasName: !trimmed.isEmpty)
    }
}
