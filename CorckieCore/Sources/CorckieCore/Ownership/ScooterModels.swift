import Foundation

/// B102 (.05): what the app knows about each scooter model's battery pack (P-6: from this table, never from one rider).
/// A model's pack gives the default battery size (the rider can still change it per scooter in Settings) and, for scooters
/// that send no battery %, the cell count to read % from the resting voltage.
public struct PackSpec: Equatable, Sendable {
    public let nominalV: Double
    public let cells: Int
    public let packAh: Double

    public init(nominalV: Double, cells: Int, packAh: Double) {
        self.nominalV = nominalV
        self.cells = cells
        self.packAh = packAh
    }

    /// Li-ion full charge, 4.2 V per cell
    public var fullV: Double { Double(cells) * 4.2 }
}

public enum ScooterModels {
    /// Model name (as KnownScooters / the Garage names it) -> pack. Add a model only with its maker's pack spec.
    public static let packs: [String: PackSpec] = [
        "RND G100": PackSpec(nominalV: 48, cells: 13, packAh: T.t42DefaultPackAh),   // 54.6 V full; the G100 sends its own %
        "RND G500": PackSpec(nominalV: 60, cells: 16, packAh: 21),                  // 67.2 V full, ~1260 Wh; sends no %
    ]

    public static func pack(model: String?) -> PackSpec? { model.flatMap { packs[$0] } }

    /// The model whose packets have this layout (for scooters that send no %)
    public static func model(for layout: ScooterLayout) -> String {
        switch layout {
        case .g2: return "RND G100"
        case .g500: return "RND G500"
        }
    }
}

/// B102 (.05): Li-ion (NMC) state of charge from the RESTING voltage per cell. A typical open-circuit curve; under load the
/// voltage sags, so callers read it only at rest (`T.t40RestedCurrentA`). Shown as an estimate where the UI already does.
public enum LiIonCurve {
    /// (volts per cell, %), rising
    public static let points: [(v: Double, pct: Double)] = [
        (3.30, 0), (3.50, 5), (3.62, 10), (3.70, 20), (3.75, 30), (3.79, 40), (3.82, 50),
        (3.87, 60), (3.93, 70), (4.00, 80), (4.10, 90), (4.20, 100),
    ]

    public static func pct(cellV: Double) -> Int {
        guard let first = points.first, let last = points.last else { return 0 }
        if cellV <= first.v { return 0 }
        if cellV >= last.v { return 100 }
        for i in 1..<points.count where cellV <= points[i].v {
            let a = points[i - 1], b = points[i]
            let p = a.pct + (cellV - a.v) / (b.v - a.v) * (b.pct - a.pct)
            return Int(p.rounded())
        }
        return 100
    }

    public static func pct(packV: Double, cells: Int) -> Int {
        guard cells > 0 else { return 0 }
        return pct(cellV: packV / Double(cells))
    }
}
