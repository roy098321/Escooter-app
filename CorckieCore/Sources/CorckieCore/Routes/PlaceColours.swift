import Foundation

/// F-08: the colour of a place (pin on the maps, strip on ride rows, dot in the list). A colour-blind-safe set (Okabe-Ito); Home is
/// green and Work is blue when they are named so, everything else takes the next colour not used yet. Stored per place as a setting
/// (`place.colour.<id>`), no schema change.
public enum PlaceColours {
    public struct Choice: Equatable, Sendable {
        public let id: String
        public let name: String
        public let hex: String
    }

    public static let all: [Choice] = [
        Choice(id: "green", name: "Green", hex: "#009E73"),
        Choice(id: "blue", name: "Blue", hex: "#0072B2"),
        Choice(id: "orange", name: "Orange", hex: "#E69F00"),
        Choice(id: "pink", name: "Pink", hex: "#CC79A7"),
        Choice(id: "vermillion", name: "Vermillion", hex: "#D55E00"),
        Choice(id: "sky", name: "Sky", hex: "#56B4E9"),
        Choice(id: "yellow", name: "Yellow", hex: "#F0E442")
    ]

    /// the grey of a ride that ended at no saved place
    public static let greyHex = "#8E8E93"

    /// the order "the next colour" is taken in (green and blue are kept for Home and Work)
    static let otherOrder = ["orange", "pink", "vermillion", "sky", "yellow", "green", "blue"]

    public static func settingKey(_ placeId: String) -> String { "place.colour.\(placeId)" }

    public static func hex(_ id: String?) -> String {
        all.first { $0.id == id }?.hex ?? greyHex
    }

    public static func isValid(_ id: String) -> Bool { all.contains { $0.id == id } }

    /// The colours for places that have none yet, in the order given (oldest first). `existing` = placeId to colour id already stored.
    /// Returns only the new assignments.
    public static func assign(places: [(id: String, name: String?)], existing: [String: String]) -> [String: String] {
        var used = Set(existing.values)
        var result: [String: String] = [:]
        for p in places where existing[p.id] == nil {
            let lower = (p.name ?? "").lowercased()
            var pick: String?
            if lower.contains("home"), !used.contains("green") { pick = "green" }
            else if lower.contains("work"), !used.contains("blue") { pick = "blue" }
            if pick == nil { pick = otherOrder.first { !used.contains($0) } }
            if pick == nil { pick = otherOrder[(used.count + result.count) % otherOrder.count] }   // all taken: start again
            result[p.id] = pick
            used.insert(pick!)
        }
        return result
    }
}
