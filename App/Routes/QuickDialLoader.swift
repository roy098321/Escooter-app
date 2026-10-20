import CorckieCore
import Foundation
import GRDB

/// One round button on Home's quick dial (F-29)
struct QuickDialItem: Identifiable, Equatable {
    /// the place id
    var id: String
    var name: String
    var icon: PlaceIcon
    /// the id the Where to? choice uses: a saved route that ends here (its id), else "place:<id>" (B31)
    var key: String
}

/// F-29 / B31: reads the places into the quick dial and the Where to? list. Compiled into AppTests too, so it takes the phone's location as
/// a parameter and never reads a sensor itself.
enum QuickDialLoader {
    static let placePrefix = "place:"

    static func placeId(fromKey key: String?) -> String? {
        guard let key, key.hasPrefix(placePrefix) else { return nil }
        return String(key.dropFirst(placePrefix.count))
    }

    // MARK: Stored per place (settings, no schema change): place.icon.<id> and place.home.<id>

    static func icons(_ database: AppDatabase) -> [String: PlaceIcon] {
        var out: [String: PlaceIcon] = [:]
        for (key, json) in settings(database, prefix: "place.icon.") {
            if let icon = PlaceIcon.parse(decodeString(json)) { out[key] = icon }
        }
        return out
    }

    /// placeId to its slot on Home (1, 2, 3 ...)
    static func pins(_ database: AppDatabase) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, json) in settings(database, prefix: "place.home.") {
            if let data = json.data(using: .utf8), let n = try? JSONDecoder().decode(Int.self, from: data), n >= 1 { out[key] = n }
        }
        return out
    }

    static func setIcon(_ icon: PlaceIcon?, placeId: String, database: AppDatabase) throws {
        let key = PlaceIcon.settingKey(placeId)
        guard let icon else { return try remove(key, database) }
        try RideQueries(database).setSetting(key: key, json: encode(icon.code))
    }

    /// slot nil = not on Home
    static func setPin(_ slot: Int?, placeId: String, database: AppDatabase) throws {
        let key = QuickDial.homeKey(placeId)
        guard let slot else { return try remove(key, database) }
        try RideQueries(database).setSetting(key: key, json: String(max(1, slot)))
    }

    private static func remove(_ key: String, _ database: AppDatabase) throws {
        guard !database.isReadOnly else { return }
        try database.writer.write { db in try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key]) }
    }

    private static func encode(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func decodeString(_ json: String) -> String? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(String.self, from: $0) }
    }

    /// placeId (the key without the prefix) to the stored JSON text
    private static func settings(_ database: AppDatabase, prefix: String) -> [(String, String)] {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT key, json FROM setting WHERE key LIKE ?", arguments: [prefix + "%"])
        }) ?? []
        return rows.map { r in
            let key: String = r["key"]
            let json: String = r["json"]
            return (String(key.dropFirst(prefix.count)), json)
        }
    }

    /// placeId to the number of real rides that ended there
    static func visits(_ database: AppDatabase) -> [String: Int] {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT endPlaceId, COUNT(*) AS n FROM ride WHERE endPlaceId IS NOT NULL AND isSimulated = 0 GROUP BY endPlaceId")
        }) ?? []
        var out: [String: Int] = [:]
        for r in rows {
            let id: String = r["endPlaceId"]
            let n: Int = r["n"]
            out[id] = n
        }
        return out
    }

    // MARK: The Where to? list and the quick dial

    /// - routeChips: the chips of the saved routes (`RouteFollowLoader.chips`)
    /// - from: where the phone is now (nil = unknown: place destinations then carry no time and no battery figure)
    static func load(database: AppDatabase, routeChips: [WhereToChip], slots: Int, from: GeoPoint?,
                     nowMs: Int64 = RouteCardLoader.currentMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin())
        -> (chips: [WhereToChip], items: [QuickDialItem]) {
        let store = RouteQueries(database)
        let places = ((try? store.places()) ?? []).filter { !($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let savedRoutes = ((try? store.routes()) ?? []).filter { $0.state == "saved" }
        let allRides = savedRoutes.flatMap { RouteCardLoader.stats((try? store.routeRides(routeId: $0.id)) ?? []) }
        let mps = PlaceDestination.usualMps(allRides)
        let pctPerKm = DestinationRules.usualPctPerKm(rides: allRides)
        let visitCounts = visits(database)
        let iconMap = icons(database)
        let pinMap = pins(database)

        var chips = routeChips
        var keyForPlace: [String: String] = [:]
        for p in places {
            // a saved route that ends here (and has a chip) is used as it is
            if let r = savedRoutes.first(where: { route in route.toPlaceId == p.id && routeChips.contains(where: { chip in chip.routeId == route.id }) }) {
                keyForPlace[p.id] = r.id
                continue
            }
            let name = p.name ?? ""
            let est = from.flatMap { PlaceDestination.estimate(distanceM: Geo.distanceM($0, GeoPoint(lat: p.lat, lon: p.lon)), usualMps: mps, usualPctPerKm: pctPerKm) }
            var chip = WhereToChip(routeId: placePrefix + p.id, label: name, detail: detail(name: name, estimate: est))
            if let est {
                let arrive = Double(nowMs) / 1000 + est.timeS
                let local = Int64(arrive) + Int64(utcOffsetMin) * 60
                let minute = Int((((local % 86_400) + 86_400) % 86_400) / 60)
                chip.timeText = "\(est.minutes) min"
                chip.arriveText = DayClock.clockText(minuteOfDay: minute)
                chip.usedText = est.usedPct.map { "\(Int($0.rounded()))%" }
                chip.usualNeedPct = est.usedPct
            }
            chips.append(chip)
            keyForPlace[p.id] = chip.routeId
        }

        let ranked = QuickDial.slots(places.map { QuickDialPlace(id: $0.id, name: $0.name, visits: visitCounts[$0.id] ?? 0, pinOrder: pinMap[$0.id]) },
                                     count: slots)
        let items: [QuickDialItem] = ranked.compactMap { id in
            guard let p = places.first(where: { $0.id == id }), let key = keyForPlace[id] else { return nil }
            return QuickDialItem(id: id, name: p.name ?? "", icon: iconMap[id] ?? PlaceIcon.automatic(name: p.name), key: key)
        }
        return (chips, items)
    }

    private static func detail(name: String, estimate: PlaceDestination.Estimate?) -> String {
        guard let e = estimate else { return name }
        var parts = [name, "about \(e.minutes) min in a straight line"]
        if let u = e.usedPct { parts.append("uses about \(Int(u.rounded()))%") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The line under the quick dial for the chosen chip (or "No destination")
    static func summary(chip: WhereToChip?) -> String {
        guard let chip else { return QuickDial.summary(name: nil, minutes: nil, needPct: nil) }
        let minutes = chip.timeText.flatMap { Int($0.split(separator: " ").first ?? "") }
        return QuickDial.summary(name: chip.label, minutes: minutes, needPct: chip.usualNeedPct)
    }
}
