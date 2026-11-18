import CorckieCore
import Foundation
import Observation

/// A-14 / A-15 (batch 9): the real range (your recent %/km and the reserve, as on the Battery page) loaded once at the ride start,
/// so the live battery tile and the voice say the SAME km left at the same level (`KmLeft`). nil = still learning.
@Observable
final class LiveRange {
    static let shared = LiveRange()
    private(set) var range: RealRange?

    private init() {}

    func load(_ overview: BatteryOverview?) { range = overview?.range }

    /// Whole km left at this level; the tile passes its shown %, the voice the same rounded smoothed level
    func km(levelPct: Double?) -> Int? { KmLeft.km(levelPct: levelPct.map { $0.rounded() }, range: range) }
}
