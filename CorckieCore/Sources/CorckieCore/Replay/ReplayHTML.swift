import Foundation

/// M5-04: puts a ride's data (and its map tiles) into the page. `tileHref` decides where a tile comes from: a `data:` address for the
/// downloaded file, a `corckie-tile://` address for the in-app viewer, nil to leave a tile out (offline, nothing cached).
public enum ReplayHTML {
    /// - colourBlind: the colour-blind speed colours (M6-03); highContrast: the sunlight style, black on white (M6-03)
    public static func build(_ data: ReplayData, colourBlind: Bool = false, highContrast: Bool = false,
                             tileHref: (ReplayTile) -> String?) -> String {
        var html = ReplayTemplate.html
        if colourBlind {
            let list = SpeedPalette.colourBlindHex.map { "'" + $0.lowercased() + "'" }.joined(separator: ", ")
            html = html.replacingOccurrences(of: "var HEX = ['#7fd37f', '#22b24c', '#f2d21b', '#f28c1b', '#e53935'];", with: "var HEX = [" + list + "];")
        }
        if highContrast {
            let css = ":root{--bg:#ffffff;--card:#ffffff;--ink:#000000;--mut:#202020;--line:#000000;--map:#ffffff}body{font-weight:600}"
            html = html.replacingOccurrences(of: "</style>", with: css + "</style>")
        }
        html = html.replacingOccurrences(of: "/*TITLE*/", with: escape(data.title))
        html = html.replacingOccurrences(of: "/*TILES*/", with: tilesMarkup(data, tileHref: tileHref))
        html = html.replacingOccurrences(of: "/*DATA*/null", with: json(data))
        return html
    }

    static func tilesMarkup(_ data: ReplayData, tileHref: (ReplayTile) -> String?) -> String {
        guard let m = data.map else { return "" }
        var out = ""
        for tile in ReplayBuilder.tiles(for: data) {
            guard let href = tileHref(tile) else { continue }
            let x = Double(tile.x) * 256 - m.ox
            let y = Double(tile.y) * 256 - m.oy
            out += String(format: "<image x=\"%.2f\" y=\"%.2f\" width=\"256.6\" height=\"256.6\" href=\"", x, y) + href + "\"/>"
        }
        return out
    }

    /// JSON that is safe inside a script element
    static func json(_ data: ReplayData) -> String {
        let encoder = JSONEncoder()
        guard let bytes = try? encoder.encode(data), let text = String(data: bytes, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// "Ride Replay – Morning ride 2026-10-06.html" (no characters a file system dislikes)
    public static func fileName(title: String, isoDate: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let clean = title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return "Ride Replay \u{2013} \(clean.isEmpty ? "Ride" : clean) \(isoDate).html"
    }
}
