import CorckieCore
import MapKit
import SwiftUI

/// Batch 102 (FIN-2 item 6, owner 27 Oct): ride detail looks and works like Replay. Replay's working part is copied as it is into the
/// ride's card: its chart strip with the cursor (drag to scrub), its controls (play / pause, the time slider, 1× / 5× / 20×) and its
/// moment tiles; the dot it moves is drawn on the ride map (the parent gets it through `dot`). Same Core pieces as Replay
/// (`ReplayTrack`, `ComparePlayback`, `ChartCursor`); full-screen Replay stays in the ⋯ menu.
struct RideReplayStrip: View {
    let rideId: String?
    @Binding var dot: CLLocationCoordinate2D?

    @State private var track: ReplayTrack?
    @State private var strip: [TimeChart.Point] = []
    @State private var playback = ComparePlayback(durationS: 0)
    @State private var lastTick: Date?
    @State private var loaded = false
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let track, !track.isEmpty, playback.durationS > 0 {
                let state = track.state(atTime: playback.time)
                VStack(spacing: 10) {
                    tiles(state)
                    TimeChart(points: strip, domain: 0...max(1, track.durationS), cursor: playback.time, colour: Theme.accent,
                              unit: ReplayLayer.speed.unit, height: 84) { t in
                        playback.pause()
                        playback.scrub(to: t)
                    }
                    controls
                }
                .onChange(of: playback.time) { _, _ in moveDot() }
            }
        }
        .onAppear(perform: load)
        .onReceive(ticker) { now in
            guard playback.playing else { lastTick = nil; return }
            let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
            lastTick = now
            playback.advance(by: min(dt, 0.2))
        }
        .onDisappear { playback.pause() }
    }

    /// Replay's moment tiles (the values under the dot)
    private func tiles(_ s: ReplayTrack.State?) -> some View {
        StatTileGrid {
            StatTile(value: s?.speedKmh.map { "\(Int($0.rounded())) km/h" } ?? "\u{2013}", label: "Speed")
            StatTile(value: s?.batteryPct.map { "\($0)%" } ?? "\u{2013}", label: "Battery")
            StatTile(value: s.map { String(format: "%.2f km", $0.distM / 1_000) } ?? "\u{2013}", label: "Distance")
        }
    }

    /// Replay's controls, unchanged
    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    if playback.playing { playback.pause() } else { playback.play() }
                } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.playing ? "Pause" : "Play")
                Slider(value: Binding(get: { playback.time }, set: { playback.scrub(to: $0) }), in: 0...max(1, playback.durationS))
                    .accessibilityLabel("Position in time")
                    .accessibilityValue(ChartCursor.clock(playback.time))
                GlassSegmented(options: ReplayView.speeds.map { ($0, "\(Int($0))\u{00D7}") },
                               selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) }))
                    .frame(width: 132)
                    .accessibilityLabel("Playback speed")
            }
            HStack {
                Text(ChartCursor.clock(playback.time)).monospacedDigit()
                Spacer()
                Text(ChartCursor.clock(playback.durationS)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func moveDot() {
        guard let s = track?.state(atTime: playback.time), let lat = s.lat, let lon = s.lon else { return }
        dot = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = rideId, let db = AppModel.shared.displayDatabase, let ride = ReplayDataLoader.load(db, rideId: id) else { return }
        let t = ReplayTrack.from(ride.data)
        guard !t.isEmpty else { return }
        track = t
        playback = ComparePlayback(durationS: t.durationS)
        playback.setSpeed(20)
        var points: [TimeChart.Point] = []
        for s in t.samples {
            if let v = t.value(.speed, s) { points.append(TimeChart.Point(id: points.count, t: s.t, v: v)) }
        }
        strip = points
        moveDot()
    }
}

/// The dot Replay moves, as Replay draws it
struct ReplayDotMark: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(radius: 2)
            .accessibilityLabel("The scooter at the replay time")
    }
}
