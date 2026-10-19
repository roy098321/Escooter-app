import CorckieCore
import MapKit
import SwiftUI

/// F-05: the shared map of the Compare sheet. Ride A solid, ride B dashed, two colour-blind-safe colours (blue / orange) and different
/// shapes for the two dots. Tap a point: both rides' speed and time from the start. Synced playback: one clock for both rides, 1-50 times
/// faster, two dots and a live "B is 0:42 later at this point". A comparison tool, not a race: no winner, no scores, no badges (P-3).
/// The maths is Core `CompareMap` (unit tested); this view draws it.
struct CompareMapView: View {
    let pathA: ComparePath
    let pathB: ComparePath
    let titleA: String
    let titleB: String
    /// ui-shots: start the clock here and show a tapped point
    var initialTime: Double?
    var initialTap: CLLocationCoordinate2D?

    static let colourA = Color(red: 0.0, green: 0.447, blue: 0.698)     // Okabe-Ito blue
    static let colourB = Color(red: 0.902, green: 0.624, blue: 0.0)     // Okabe-Ito orange
    /// Both lines are drawn this far to the right / left of their true line, so shared stretches show side by side
    static let sideOffsetM = 3.0

    @State private var playback: ComparePlayback
    @State private var matches: [CompareMatch?] = []
    @State private var lineA: [CLLocationCoordinate2D] = []
    @State private var lineB: [CLLocationCoordinate2D] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var tap: CLLocationCoordinate2D?
    @State private var lastTick: Date?
    @State private var ready = false
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(pathA: ComparePath, pathB: ComparePath, titleA: String, titleB: String, initialTime: Double? = nil, initialTap: CLLocationCoordinate2D? = nil) {
        self.pathA = pathA
        self.pathB = pathB
        self.titleA = titleA
        self.titleB = titleB
        self.initialTime = initialTime
        self.initialTap = initialTap
        _playback = State(initialValue: ComparePlayback(durationS: max(pathA.durationS, pathB.durationS)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            mapView
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            controls
            readout
        }
        .onAppear(perform: setUp)
        .onReceive(ticker) { now in
            guard playback.playing else { lastTick = nil; return }
            let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
            lastTick = now
            playback.advance(by: min(dt, 0.2))
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(colour: Self.colourA, dashed: false, shape: "circle.fill", name: "A", title: titleA)
            legendRow(colour: Self.colourB, dashed: true, shape: "diamond.fill", name: "B", title: titleB)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private func legendRow(colour: Color, dashed: Bool, shape: String, name: String, title: String) -> some View {
        HStack(spacing: 8) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dashed ? [7, 5] : []))
            }
            .frame(width: 34, height: 10)
            Image(systemName: shape).foregroundStyle(colour).font(.caption)
            Text("\(name) \u{00B7} \(title)").lineLimit(1)
            Text(dashed ? "dashed" : "solid").foregroundStyle(.secondary)
        }
    }

    // MARK: Map

    private var dotA: CLLocationCoordinate2D? { pathA.position(atTime: playback.time).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
    private var dotB: CLLocationCoordinate2D? { pathB.position(atTime: playback.time).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: lineA)
                    .stroke(Self.colourA, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: lineB)
                    .stroke(Self.colourB, style: StrokeStyle(lineWidth: 4, lineCap: .butt, lineJoin: .round, dash: [9, 6]))
                if let d = dotA, showDots {
                    Annotation("", coordinate: d) { dot(shape: "circle.fill", colour: Self.colourA, letter: "A") }
                }
                if let d = dotB, showDots {
                    Annotation("", coordinate: d) { dot(shape: "diamond.fill", colour: Self.colourB, letter: "B") }
                }
                if let t = tap {
                    Annotation("", coordinate: t) {
                        Image(systemName: "scope").font(.title3.weight(.bold)).foregroundStyle(.primary)
                            .padding(4).background(Circle().fill(.thinMaterial))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { location in
                if let c = proxy.convert(location, from: .local) { tap = c }
            }
        }
        .accessibilityLabel("Map with both rides. A is the solid line, B the dashed line. Tap a point for both rides' speed and time.")
    }

    /// The dots show once the clock was started or moved (at 0:00 both sit at the start)
    private var showDots: Bool { playback.time > 0 || playback.playing }

    private func dot(shape: String, colour: Color, letter: String) -> some View {
        ZStack {
            Image(systemName: shape).font(.system(size: 26)).foregroundStyle(colour)
            Text(letter).font(.caption2.weight(.heavy)).foregroundStyle(.white)
        }
        .shadow(radius: 2)
    }

    // MARK: Playback controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    if playback.playing { playback.pause() } else { playback.play() }
                } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                }
                .accessibilityLabel(playback.playing ? "Pause" : "Play both rides")
                Slider(value: Binding(get: { playback.time }, set: { playback.scrub(to: $0) }),
                       in: 0...max(1, playback.durationS))
                    .accessibilityLabel("Position in time")
                    .accessibilityValue(CompareAlign.timeFromStart(playback.time))
                Menu {
                    ForEach(ComparePlayback.speeds, id: \.self) { s in
                        Button("\(Int(s))\u{00D7}") { playback.setSpeed(s) }
                    }
                } label: {
                    Text("\(Int(playback.speed))\u{00D7}").monospacedDigit().frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Playback speed")
            }
            HStack {
                Text(CompareAlign.timeFromStart(playback.time)).monospacedDigit()
                Spacer()
                Text(CompareAlign.timeFromStart(playback.durationS)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Read-out

    private var liveDelta: Double? {
        CompareAlign.delta(atTimeA: min(playback.time, pathA.durationS), matches: matches, path: pathA)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showDots {
                VStack(alignment: .leading, spacing: 2) {
                    Text(liveDelta.map { CompareAlign.clock($0) } ?? "\u{2013}")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text(CompareAlign.differenceText(liveDelta)).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let t = tap {
                let a = pathA.readout(nearLat: t.latitude, lon: t.longitude)
                let b = pathB.readout(nearLat: t.latitude, lon: t.longitude)
                VStack(alignment: .leading, spacing: 4) {
                    Text("At the tapped point").font(.footnote.weight(.semibold))
                    readoutRow("A", Self.colourA, a)
                    readoutRow("B", Self.colourB, b)
                    if let a, let b {
                        Text("\(CompareAlign.differenceText(b.timeS - a.timeS))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if !showDots {
                Text("Tap the map for both rides' speed and time at that point, or press play to run both rides on one clock.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func readoutRow(_ name: String, _ colour: Color, _ r: CompareReadout?) -> some View {
        HStack {
            Text(name).font(.subheadline.weight(.bold)).foregroundStyle(colour).frame(width: 20, alignment: .leading)
            if let r {
                Text("\(CompareAlign.timeFromStart(r.timeS)) from the start").monospacedDigit()
                Spacer()
                Text(r.speedKmh.map { "\(Int($0.rounded())) km/h" } ?? "\u{2013}").monospacedDigit()
            } else {
                Text("Not on this ride's line").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.subheadline)
    }

    // MARK: Set-up

    private func setUp() {
        guard !ready else { return }
        ready = true
        matches = CompareAlign.match(pathA, pathB)
        lineA = pathA.offset(byM: Self.sideOffsetM).points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        lineB = pathB.offset(byM: -Self.sideOffsetM).points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        camera = Self.region(pathA, pathB)
        if let t = initialTime { playback.scrub(to: t) }
        if let t = initialTap { tap = t }
    }

    static func region(_ a: ComparePath, _ b: ComparePath) -> MapCameraPosition {
        let all = a.points + b.points
        guard let first = all.first else { return .automatic }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in all {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.002), longitudeDelta: max((maxLon - minLon) * 1.4, 0.002))))
    }
}

/// Loads both rides' stored positions for the shared map (read-only).
enum CompareMapLoader {
    static func path(_ db: AppDatabase, rideId: String) -> ComparePath {
        let samples = (try? RideQueries(db).samples(rideId: rideId)) ?? []
        let points = samples.map { s in
            RidePoint(t: s.t, lat: s.lat, lon: s.lon, hAccM: s.hAccM, speedKmh: s.speedMps.map { $0 * 3.6 },
                      gpsSpeedKmh: s.gpsSpeedMps.map { $0 * 3.6 }, batteryPct: s.batteryPct, mode: s.mode)
        }
        return ComparePath.build(points)
    }
}

/// Made-up paths for the CI ui-shots (`-uiShot ride-compare`): two rides on nearly the same road, B slower with a stop and a short detour.
enum CompareMapPreview {
    static func paths() -> (ComparePath, ComparePath) {
        func ride(speedScale: Double, stopAt: Int?, detour: Bool) -> ComparePath {
            var pts: [RidePoint] = []
            var t = 0.0
            for i in 0..<60 {
                let x = Double(i)
                var lat: Double = 40.0 + x * 0.00018
                var lon: Double = -75.0 + x * 0.00022 + 0.0006 * sin(x / 6)
                if detour, i > 22, i < 34 { lon += 0.0011 * sin(Double(i - 22) / 11 * .pi); lat += 0.0002 * sin(Double(i - 22) / 11 * .pi) }
                let kmh: Double = (12 + 22 * abs(sin(x / 9))) * speedScale
                pts.append(RidePoint(t: Int64(t * 1000), lat: lat, lon: lon, hAccM: 6, speedKmh: kmh))
                t += 5 / speedScale
                if let s = stopAt, i == s { t += 25 }
            }
            return ComparePath.build(pts)
        }
        return (ride(speedScale: 1.0, stopAt: nil, detour: false), ride(speedScale: 0.9, stopAt: 30, detour: true))
    }

    static var tapPoint: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 40.0 + 40 * 0.00018, longitude: -75.0 + 40 * 0.00022 + 0.0006 * sin(40.0 / 6)) }
}
