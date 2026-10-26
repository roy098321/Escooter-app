import Foundation

/// Hotfix 01 (H4, owner 25 Oct): the Stats chart's dashed lines. Step = (top bar ÷ 3) rounded to the NEAREST comfortable number,
/// lines at 1, 2 and 3 steps, so the top line sits about at the top bar (13 km → 5 / 10 / 15, 99 ₪ → 30 / 60 / 90, 7 rides → 2 / 4 / 6).
/// Comfortable numbers: 1, 2, 2.5, 3, 5 × 10ⁿ (3 so that 99 → 30, the owner's example); rides and ₪ never get a decimal step;
/// time (minutes) uses nice minutes and hours. Pure, tested on Linux.
public enum ReferenceLines {
    static let comfortable: [Double] = [1, 2, 2.5, 3, 5, 10]
    static let wholeComfortable: [Double] = [1, 2, 3, 5, 10]
    /// nice minute steps, then hours
    static let minuteSteps: [Double] = [1, 2, 5, 10, 15, 20, 30, 60, 90, 120, 180, 240, 300, 360, 480, 600, 720]

    /// The step for a top bar (0 when there is nothing to draw)
    public static func step(top: Double, metric: PastWeeksMetric = .km) -> Double {
        guard top > 0, top.isFinite else { return 0 }
        let raw = top / 3
        if metric == .time {
            return minuteSteps.min { abs($0 - raw) < abs($1 - raw) } ?? raw
        }
        let whole = metric == .rides || metric == .saved
        let magnitude = pow(10, floor(log10(raw)))
        let list = (whole ? wholeComfortable : comfortable).map { $0 * magnitude }
        let nearest = list.min { abs($0 - raw) < abs($1 - raw) } ?? raw
        return whole ? max(1, nearest.rounded()) : nearest
    }

    /// The lines: 1, 2, 3 steps (for a whole-number metric whose top is below 3, only the lines up to the top)
    public static func steps(top: Double, metric: PastWeeksMetric = .km) -> [Double] {
        let s = step(top: top, metric: metric)
        guard s > 0 else { return [] }
        let lines = (1...3).map { Double($0) * s }
        if (metric == .rides || metric == .saved), s == 1, top < 3 {
            return lines.filter { $0 <= max(1, top.rounded(.up)) }
        }
        return lines
    }

    /// The chart's value scale so the bars and the lines share it: 0 up to the higher of the top bar and the top line
    public static func domainTop(top: Double, lines: [Double]) -> Double {
        max(top, lines.last ?? 0, 0.001)
    }
}
