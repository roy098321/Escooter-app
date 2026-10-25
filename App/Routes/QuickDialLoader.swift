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
    /// the place colour (an id of `PlaceColours`) and whether the phone is inside the place's circle (B46)
    var colourId: String = "orange"
    var here = false
}

/// F-29 / B31: reads the places into the quick dial and the Where to? list. Compiled into AppTests too, so it takes the phone's location as
/// a parameter and never reads a sensor itself.
enum QuickDialLoader {
    static let placePrefix = "place:"
    /// B55: why the last `load` could not read the places or routes (nil = it could); the caller logs it, the row is shown anyway
    private(set) static var lastFailure: String?

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
    /// - from: where the phone is now (nil = unknown: no place is "here")
    /// P6-5: a place's time comes only from rides that ended there (B44, B45); no straight-line guess. A place the phone is inside is "here" (B46).
    static func load(database: AppDatabase, routeChips: [WhereToChip], slots: Int, from: GeoPoint?,
                     nowMs: Int64 = RouteCardLoader.currentMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin())
        -> (chips: [WhereToChip], items: [QuickDialItem], rows: [WhereToRow]) {
        let store = RouteQueries(database)
        // B55: a failed read used to vanish silently (try?) and hid the whole quick dial; it is kept for the log now
        var failures: [String] = []
        var allPlaces: [PlaceRecord] = []
        var allRoutes: [RouteRecord] = []
        do { allPlaces = try store.places() } catch { failures.append("places: \(error.localizedDescription)") }
        do { allRoutes = try store.routes() } catch { failures.append("routes: \(error.localizedDescription)") }
        lastFailure = failures.isEmpty ? nil : failures.joined(separator: "; ")
        let places = allPlaces.filter { !($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let savedRoutes = allRoutes.filter { $0.state == "saved" }
        let visitCounts = visits(database)
        let iconMap = icons(database)
        let pinMap = QuickDialSlot.normalized(pins(database))
        let colourMap = PlaceColourStore.colours(database: database)

        var chips = routeChips
        var keyForPlace: [String: String] = [:]
        // B61: the named place each saved route ends at (the circle its end falls inside, else its link, else the same name); the route and
        // the place are then one row, and a second route to the same place is not a second row
        let named = places.map { WhereToDedupe.NamedPlace(id: $0.id, name: $0.name ?? "", center: GeoPoint(lat: $0.lat, lon: $0.lon), radiusM: $0.radiusM) }
        var endOf: [String: String] = [:]
        for route in savedRoutes {
            let label = routeChips.first { $0.routeId == route.id }?.label ?? ""
            if let p = WhereToDedupe.endPlace(toPlaceId: route.toPlaceId, end: routeEnd(route, store: store), label: label, places: named) {
                endOf[route.id] = p
            }
        }
        var dropped = Set<String>()
        for p in places {
            let name = p.name ?? ""
            // every ride that ended here: the rides of the saved routes that end here and the rides whose end place is this one, each once
            var rows: [RouteRideRow] = []
            var seen = Set<String>()
            for route in savedRoutes where endOf[route.id] == p.id {
                for r in (try? store.routeRides(routeId: route.id)) ?? [] where seen.insert(r.id).inserted { rows.append(r) }
            }
            for r in (try? store.placeRides(placeId: p.id)) ?? [] where seen.insert(r.id).inserted { rows.append(r) }
            let verdict = PlaceRides.verdict(rides: RouteCardLoader.stats(rows), nowMs: nowMs, utcOffsetMin: utcOffsetMin)
            let here = PlaceHere.isHere(phone: from, place: GeoPoint(lat: p.lat, lon: p.lon), radiusM: p.radiusM)

            // a saved route that ends here (and has a chip) is used as it is; without a usual estimate it takes the place's rides (B45).
            // B61: with two routes here (from different starts) the one with an estimate is the row; the other is no second row.
            let routesHere = savedRoutes.filter { route in endOf[route.id] == p.id && routeChips.contains(where: { chip in chip.routeId == route.id }) }
            let withTime = routesHere.first { route in routeChips.first(where: { $0.routeId == route.id })?.timeText != nil }
            if let r = withTime ?? routesHere.first, let i = chips.firstIndex(where: { $0.routeId == r.id }) {
                keyForPlace[p.id] = r.id
                for other in routesHere where other.id != r.id { dropped.insert(other.id) }
                chips[i].label = name
                chips[i].here = here
                if chips[i].timeText == nil { apply(verdict, to: &chips[i], name: name, nowMs: nowMs, utcOffsetMin: utcOffsetMin) }
                continue
            }
            var chip = WhereToChip(routeId: placePrefix + p.id, label: name, detail: name)
            chip.here = here
            apply(verdict, to: &chip, name: name, nowMs: nowMs, utcOffsetMin: utcOffsetMin)
            chips.append(chip)
            keyForPlace[p.id] = chip.routeId
        }

        chips.removeAll { dropped.contains($0.routeId) }

        let ranked = QuickDial.slots(places.map { QuickDialPlace(id: $0.id, name: $0.name, visits: visitCounts[$0.id] ?? 0, pinOrder: pinMap[$0.id]) },
                                     count: slots)
        func hereFlag(_ key: String) -> Bool { chips.first(where: { $0.routeId == key })?.here ?? false }
        let items: [QuickDialItem] = ranked.compactMap { id in
            guard let p = places.first(where: { $0.id == id }), let key = keyForPlace[id] else { return nil }
            return QuickDialItem(id: id, name: p.name ?? "", icon: iconMap[id] ?? PlaceIcon.automatic(name: p.name), key: key,
                                 colourId: colourMap[id] ?? "orange", here: hereFlag(key))
        }
        var rows: [WhereToRow] = chips.map { chip in
            if let p = places.first(where: { keyForPlace[$0.id] == chip.routeId }) {
                return WhereToRow(key: chip.routeId, name: chip.label, icon: iconMap[p.id] ?? PlaceIcon.automatic(name: p.name), colourId: colourMap[p.id] ?? "orange",
                                  placeId: p.id, here: chip.here, pin: pinMap[p.id], timeText: chip.timeText, arriveText: chip.arriveText, note: chip.note,
                                  timeS: chip.timeS, needPct: chip.usualNeedPct)
            }
            return WhereToRow(key: chip.routeId, name: chip.label, icon: PlaceIcon.automatic(name: chip.label), colourId: "grey", placeId: nil,
                              here: false, pin: nil, timeText: chip.timeText, arriveText: chip.arriveText, note: chip.note, timeS: chip.timeS,
                              needPct: chip.usualNeedPct)
        }
        // B61 last guard: never two rows with the same name (a place row wins over a route row that ends at no named place)
        let kept = WhereToDedupe.keepOnePerName(rows.map { WhereToDedupe.Row(key: $0.key, name: $0.name, placeId: $0.placeId) }).map(\.key)
        if kept.count != rows.count {
            rows = kept.compactMap { k in rows.first { $0.key == k } }
            chips = chips.filter { kept.contains($0.routeId) }
        }
        return (chips, items, rows)
    }

    /// B61: where a saved route ends: its linked place's centre (named or not), else the end of its reference path
    static func routeEnd(_ route: RouteRecord, store: RouteQueries) -> GeoPoint? {
        if let id = route.toPlaceId, let p = try? store.place(id: id) { return GeoPoint(lat: p.lat, lon: p.lon) }
        let variants = (try? store.variants(routeId: route.id)) ?? []
        guard let line = (variants.first { $0.isReference } ?? variants.first)?.polyline else { return nil }
        return Geo.decode(line).last
    }

    /// Writes the verdict into a chip: the time, the arrival and the battery use, or the reason there is none
    private static func apply(_ v: PlaceRides.Verdict, to chip: inout WhereToChip, name: String, nowMs: Int64, utcOffsetMin: Int) {
        switch v {
        case .estimate(let timeS, let used, _):
            let minutes = max(1, Int((timeS / 60).rounded()))
            let arrive = Double(nowMs) / 1000 + timeS
            let local = Int64(arrive) + Int64(utcOffsetMin) * 60
            let minute = Int((((local % 86_400) + 86_400) % 86_400) / 60)
            chip.timeText = "\(minutes) min"
            chip.arriveText = DayClock.clockText(minuteOfDay: minute)
            chip.timeS = timeS
            chip.usedText = used.map { "\(Int($0.rounded()))%" }
            chip.usualNeedPct = used
            chip.note = nil
            chip.detail = [name, "about \(minutes) min", used.map { "uses about \(Int($0.rounded()))%" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case .none, .tooFew:
            chip.note = PlaceRides.note(v)
            chip.detail = [name, chip.note].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
    }

    /// The line under the quick dial for the chosen chip (or "No destination")
    static func summary(chip: WhereToChip?) -> String {
        guard let chip else { return QuickDial.summary(name: nil, minutes: nil, needPct: nil) }
        let minutes = chip.timeText.flatMap { Int($0.split(separator: " ").first ?? "") }
        return QuickDial.summary(name: chip.label, minutes: minutes, needPct: chip.usualNeedPct, note: chip.note)
    }

    /// P6-5: the pins as the Where to? sheet edited them (slot 1 to 3); everything else is unpinned
    static func writePins(_ pins: [String: Int], database: AppDatabase) throws {
        let normal = QuickDialSlot.normalized(pins)
        let existing = Set(settings(database, prefix: "place.home.").map(\.0))
        for id in existing.union(normal.keys) { try setPin(normal[id], placeId: id, database: database) }
    }
}

/// One line of the Where to? sheet (P6-5): the place's icon in its colour, its name, and the time or the reason there is none.
struct WhereToRow: Identifiable, Equatable {
    var key: String
    var name: String
    var icon: PlaceIcon
    var colourId: String
    /// nil for a route that ends at no named place (it cannot be pinned)
    var placeId: String?
    var here: Bool
    /// 1 to 3 when the place is on Home
    var pin: Int?
    var timeText: String?
    var arriveText: String?
    var note: String?
    /// B58: the ride time in seconds; the sheet shows the arrival as now + this, never the stored `arriveText`
    var timeS: Double? = nil
    /// note 14: the usual battery need, % (nil = no usual estimate: no battery part)
    var needPct: Double? = nil
    var id: String { key }
}
