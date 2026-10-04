import CorckieCore
import Foundation

/// Turns a scooter + phone stream into the Recorder's input list on a virtual clock, with a tick every second
/// (as the app's 1-s timer does). The Core tests feed it to `RideRecorderCore`, the app-tests to the real
/// Recorder actor with a temporary database, so both test the same path as the street.
public enum RecorderRunner {
    public static func inputs(_ stream: SimStream, tailS: Double = 300) -> [(t: Double, input: RecorderInput)] {
        var items: [(t: Double, input: RecorderInput)] = stream.scooter.map { (t: $0.t, input: RecorderInput.scooter($0)) }
        for e in stream.phone {
            switch e.event {
            case .fix(let f): items.append((t: e.t, input: .fix(f)))
            case .baro(let b): items.append((t: e.t, input: .baro(b)))
            default: break
            }
        }
        items = items.enumerated().sorted { a, b in a.element.t == b.element.t ? a.offset < b.offset : a.element.t < b.element.t }
            .map(\.element)
        guard let first = items.first?.t else { return [] }
        var out: [(t: Double, input: RecorderInput)] = []
        out.reserveCapacity(items.count + 4_000)
        var nextTick = first.rounded(.down) + 1
        for item in items {
            while nextTick < item.t {
                out.append((t: nextTick, input: .tick))
                nextTick += 1
            }
            out.append(item)
        }
        let end = (items.last?.t ?? first) + tailS
        while nextTick < end {
            out.append((t: nextTick, input: .tick))
            nextTick += 1
        }
        return out
    }

    /// Plays the inputs through a core and hands every action over in order.
    @discardableResult
    public static func play(_ inputs: [(t: Double, input: RecorderInput)], core: inout RideRecorderCore,
                            apply: (RecorderAction) -> Void) -> Int {
        var count = 0
        for i in inputs {
            for a in core.handle(i.input, at: i.t) {
                apply(a)
                count += 1
            }
        }
        return count
    }
}
