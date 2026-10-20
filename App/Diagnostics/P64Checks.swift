import CorckieCore
import Foundation

/// P6-4 chunk 1 check, on made-up input (nothing real is read or written):
/// u78 the pure parts of the native Replay and the full-screen charts: B38 climb battery, B39 map fit, the shared chart cursor
/// following the playback clock, the pinch zoom, and B37 battery axis ticks.
@MainActor
enum P64Checks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    static func run() {
        let expect = Expect()

        // B38: the climb's own readings only, hidden below the resolution or when it is sag, not energy
        var before: [SeriesPoint] = []
        for i in 0..<200 { before.append(SeriesPoint(t: Double(i), batteryPct: i < 100 ? 95 - i * 15 / 100 : (i < 150 ? 80 : 79))) }
        expect(RideLayers.climbBatteryUsed(before, from: 100, to: 199, distM: 600, gainM: 12) == 1, "a climb counts only its own readings (1 %, not 16 %)")
        let sag = (0..<120).map { SeriesPoint(t: Double($0), batteryPct: $0 < 60 ? 80 : 64) }
        expect(RideLayers.climbBatteryUsed(sag, from: 0, to: 119, distM: 1_200, gainM: 12) == nil, "+12 m with 16 % gone is hidden (sag)")
        let flat = (0..<60).map { SeriesPoint(t: Double($0), batteryPct: 80) }
        expect(RideLayers.climbBatteryUsed(flat, from: 0, to: 59, distM: 400, gainM: 12) == nil, "0 % (below the resolution) is hidden")

        // B39: one wild fix does not zoom the map out
        var path = (0..<50).map { GeoPoint(lat: 10 + Double($0) * 0.000_1, lon: -30) }
        path.append(GeoPoint(lat: 10.4, lon: -29.6))
        let r = MapFit.region(path, padding: 0.15, topCover: 0.3)
        expect((r?.latSpan ?? 1) < 0.02 && (r?.lonSpan ?? 1) < 0.01, "the map fits the path, not a fix 60 km away")
        expect((r?.centerLat ?? 0) > 10.002_45, "the path sits below the top bar")

        // Cursor: the playback clock, the strip cursor and the readout agree
        var pts: [SeriesPoint] = []
        for i in 0...300 {
            pts.append(SeriesPoint(t: Double(i) * 2, lat: 10 + Double(i) * 0.000_09, lon: -30, hAccM: 5, speedKmh: Double(i % 30),
                                   batteryPct: 80 - i / 100, altM: 20, powerW: 250))
        }
        let track = ReplayTrack.build(pts)
        var clock = ComparePlayback(durationS: track.durationS)
        clock.setSpeed(20)
        clock.play()
        for _ in 0..<10 { clock.advance(by: 0.1) }
        let i = ChartCursor.nearestIndex(track.times, to: clock.time) ?? -1
        expect(abs(clock.time - 20) < 1e-6 && i == 10, "1 s at 20x is 0:20 and the cursor snaps to that reading")
        let x = ChartCursor.x(ofTime: clock.time, width: 300, domain: 0...track.durationS)
        expect(abs(ChartCursor.time(atX: x, width: 300, domain: 0...track.durationS) - clock.time) < 1e-9, "finger and cursor map to the same time")
        let state = track.state(atTime: clock.time)
        expect(abs((state?.speedKmh ?? -1) - (track.samples[10].speedKmh ?? 0)) < 0.01 && state?.batteryPct == 80, "the tiles read the reading under the cursor")
        let zoom = ChartCursor.zoomed(0...600, full: 0...600, scale: 4, anchor: 0.5)
        expect(zoom == 225...375, "pinch 4x zooms in around the fingers and stays inside the ride")
        expect(ChartCursor.batteryAxis(min: 74, max: 81).ticks == [70, 80, 90], "the battery chart has three labels (B37)")
        expect(!ReplayTrack.runs(track.stretches(.speed), ramp: track.ramp(.speed, colourBlind: false)).isEmpty, "the replay path has coloured runs")

        CheckResults.shared.set("u78", expect.ok ? .pass : .fail, expect.line)
    }
}
