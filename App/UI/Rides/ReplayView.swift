import CorckieCore
import MapKit
import SwiftUI

/// F-18 (P6-4): Ride Replay, native and full screen (opened from the ride's dots menu). The MapKit path coloured by the chosen layer
/// (Speed / Battery / Power / Elevation), a dot that moves with the playback clock (Compare's `ComparePlayback`: play, pause, scrub,
/// 1x / 5x / 20x), theme tiles for the moment under the dot and a Swift Charts strip whose cursor follows the clock (drag it to scrub).
/// The maths is Core `ReplayTrack` / `ChartCursor` (unit tested). "Export → Replay file" still writes the ONE self-contained HTML file
/// (tiles embedded) for sharing; it stays on the phone until the rider shares it.
struct ReplayView: View {
    var rideId: String?
    /// ui-shot only: made-up data and no network
    var previewData: ReplayData?
    var startDownload = false

    static let speeds: [Double] = [1, 5, 20]

    @Environment(\.dismiss) private var dismiss
    @State private var ride: ReplayRide?
    @State private var track: ReplayTrack?
    @State private var missing = false
    @State private var layer: ReplayLayer = .speed
    @State private var runs: [(coords: [CLLocationCoordinate2D], colour: Color)] = []
    @State private var strip: [TimeChart.Point] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var playback = ComparePlayback(durationS: 0)
    @State private var lastTick: Date?
    @State private var building = false
    @State private var buildText = ""
    @State private var shareItem: ShareFile?
    @State private var errorText: String?
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Group {
            if let track, !track.isEmpty {
                player(track)
            } else if missing {
                VStack(spacing: 0) {
                    topBar.padding(.horizontal, DS.Space.gutter)
                    ContentUnavailableView("No replay", systemImage: "play.slash",
                                           description: Text("This ride has too few readings to replay."))
                }
            } else {
                ProgressView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
        .alert("Could not make the file", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: load)
        .onReceive(ticker) { now in
            guard playback.playing else { lastTick = nil; return }
            let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
            lastTick = now
            playback.advance(by: min(dt, 0.2))
        }
        .onChange(of: layer) { _, _ in paint() }
        .screen("Ride Replay")
    }

    // MARK: Layout

    private func player(_ track: ReplayTrack) -> some View {
        let state = track.state(atTime: playback.time)
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                mapView(state)
                    .ignoresSafeArea(.container, edges: .top)
                VStack(spacing: 10) {
                    topBar
                    HStack(alignment: .top) {
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 8) {
                            GlassLayerControl(options: layers(track).map { ($0, $0.rawValue) }, selection: $layer)
                            legend(track)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, 4)
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                tiles(state)
                TimeChart(points: strip, domain: 0...max(1, track.durationS), cursor: playback.time, colour: Theme.accent,
                          unit: layer.unit, step: layer == .battery, height: 84) { t in
                    playback.pause()
                    playback.scrub(to: t)
                }
                controls
                if building || !buildText.isEmpty {
                    Text(building ? "Getting the map\u{2026} \(buildText)" : buildText)
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.background)
        }
    }

    private var topBar: some View {
        GlassTopBar(title: "Ride Replay", subtitle: ride.map { "\($0.data.title) \u{00B7} \($0.data.date)" }) {
            GlassIconButton(symbol: "xmark", label: "Close") { dismiss() }
        } trailing: {
            if building {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button { Task { await download() } } label: { GlassIcon(symbol: "square.and.arrow.down") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Replay file")
                    .disabled(ride == nil)
            }
        }
    }

    private func mapView(_ state: ReplayTrack.State?) -> some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                MapPolyline(coordinates: run.coords)
                    .stroke(run.colour, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let state, let lat = state.lat, let lon = state.lon {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), anchor: .center) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: 3))
                        .shadow(radius: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Map of the ride, coloured by \(layer.rawValue.lowercased()). The dot is the scooter at the playback time.")
    }

    private func legend(_ track: ReplayTrack) -> some View {
        let ramp = track.ramp(layer, colourBlind: DisplaySettings.colourBlind)
        let colours = (0...8).map { GradientPath.color(ramp, ramp.lo + Double($0) / 8 * (ramp.hi - ramp.lo)) }
        return HStack(spacing: 6) {
            Text(Self.short(ramp.lo, layer)).font(.caption2).monospacedDigit()
            Capsule().fill(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)).frame(width: 64, height: 6)
            Text(Self.short(ramp.hi, layer) + " " + layer.unit).font(.caption2).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassCard(radius: DS.Radius.tile, padding: 0)
        .accessibilityElement(children: .combine)
    }

    private func tiles(_ s: ReplayTrack.State?) -> some View {
        StatTileGrid {
            StatTile(value: s?.speedKmh.map { "\(Int($0.rounded())) km/h" } ?? "\u{2013}", label: "Speed")
            StatTile(value: s?.batteryPct.map { "\($0)%" } ?? "\u{2013}", label: "Battery")
            StatTile(value: s?.powerW.map { "\(Int($0.rounded())) W" } ?? "\u{2013}", label: "Power")
            StatTile(value: s?.altM.map { String(format: "%+.0f m", $0) } ?? "\u{2013}", label: "Elevation")
            StatTile(value: s.map { String(format: "%.2f km", $0.distM / 1_000) } ?? "\u{2013}", label: "Distance")
            StatTile(value: ChartCursor.clock(playback.time), label: "Time")
        }
    }

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
                GlassSegmented(options: Self.speeds.map { ($0, "\(Int($0))\u{00D7}") },
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

    // MARK: Data

    private func layers(_ track: ReplayTrack) -> [ReplayLayer] { ReplayLayer.allCases.filter { track.has($0) } }

    static func short(_ v: Double, _ layer: ReplayLayer) -> String {
        layer == .power && v >= 1_000 ? String(format: "%.1fk", v / 1_000) : "\(Int(v.rounded()))"
    }

    private func load() {
        guard track == nil, !missing else { return }
        if let previewData {
            ride = ReplayRide(data: previewData, fileName: "Ride Replay \u{2013} Sample.html")
        } else if let id = rideId, let db = AppModel.shared.displayDatabase, let loaded = ReplayDataLoader.load(db, rideId: id) {
            ride = loaded
        }
        guard let ride else {
            missing = true
            return
        }
        let t = ReplayTrack.from(ride.data)
        guard !t.isEmpty else {
            missing = true
            return
        }
        track = t
        playback = ComparePlayback(durationS: t.durationS)
        playback.setSpeed(previewData != nil ? 5 : 20)
        if let r = MapFit.region(t.coordinates, padding: 0.15, topCover: 0.3) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.centerLat, longitude: r.centerLon),
                                                span: MKCoordinateSpan(latitudeDelta: r.latSpan, longitudeDelta: r.lonSpan)))
        }
        paint()
        if previewData != nil { playback.scrub(to: t.durationS * 0.4) }
        if startDownload { Task { await download() } }
    }

    /// The path runs and the chart strip of the chosen layer (made once per layer, not per frame)
    private func paint() {
        guard let track else { return }
        if !track.has(layer) { layer = .speed }
        let ramp = track.ramp(layer, colourBlind: DisplaySettings.colourBlind)
        runs = ReplayTrack.runs(track.stretches(layer), ramp: ramp).map { run in
            (coords: run.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }, colour: GradientPath.color(ramp, run.value))
        }
        var times: [Double] = []
        var values: [Double] = []
        for s in track.samples {
            if let v = track.value(layer, s) {
                times.append(s.t)
                values.append(v)
            }
        }
        strip = TimeChart.points(times: times, values: values, domain: 0...max(1, track.durationS), max: 400)
    }

    /// One HTML file: the page with its tiles as data addresses
    private func download() async {
        guard let ride, !building else { return }
        building = true
        buildText = ""
        defer { building = false }
        let tiles = previewData != nil ? [] : ReplayBuilder.tiles(for: ride.data)
        let got = await TileCache.shared.fetchAll(tiles) { done, total in
            DispatchQueue.main.async { buildText = "\(done) of \(total)" }
        }
        let page = ReplayHTML.build(ride.data, colourBlind: DisplaySettings.colourBlind) { tile in
            got[tile].map { "data:image/png;base64," + $0.base64EncodedString() }
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayShare", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(ride.fileName)
            try page.write(to: url, atomically: true, encoding: .utf8)
            let mb = String(format: "%.1f MB", Double(page.utf8.count) / 1_000_000)
            let missingTiles = tiles.count - got.count
            buildText = missingTiles > 0 ? "File ready (\(mb)). \(missingTiles) of \(tiles.count) map tiles could not be loaded (offline?), the file still plays."
                                         : "File ready (\(mb))."
            shareItem = ShareFile(url: url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// The iPhone share sheet for a file (Files, AirDrop, WhatsApp, mail)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
