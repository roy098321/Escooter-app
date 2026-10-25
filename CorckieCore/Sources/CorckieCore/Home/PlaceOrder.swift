import Foundation

/// Places hold to drag, release for menu (owner 21 Oct): long-press a place card and drag it to reorder (haptic per slot, light haptic on
/// drop); hold and let go without moving → the menu Rename · Colour · Icon · Show on Home. The order is one setting (`settingKey`, a JSON
/// list of place ids, no schema change); places it does not name keep their own order after the ordered ones.
public enum PlaceOrder {
    public static let settingKey = "places.order"

    /// `ids` (the stored places in their default order) sorted by the saved order
    public static func apply(_ ids: [String], saved: [String]) -> [String] {
        let present = Set(ids)
        var seen = Set<String>()
        let first = saved.filter { present.contains($0) && seen.insert($0).inserted }
        return first + ids.filter { !seen.contains($0) }
    }

    /// The order after a drag (List.onMove offsets)
    public static func moved(_ ids: [String], from: IndexSet, to: Int) -> [String] {
        var out = ids
        let moving = from.sorted().map { out[$0] }
        for i in from.sorted(by: >) { out.remove(at: i) }
        let before = from.filter { $0 < to }.count
        out.insert(contentsOf: moving, at: max(0, min(out.count, to - before)))
        return out
    }

    public static func json(_ ids: [String]) -> String {
        (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    public static func parse(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
