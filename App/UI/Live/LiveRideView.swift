import CorckieCore
import MapKit
import SwiftUI

/// M1-12 live ride view: a full-screen map, glass tiles, no tab bar and no navigation. It is shown as a full-screen
/// cover (see `RootView`) while a ride is on, or in "Ready" (D2) when the "Going for a ride?" notification was
/// tapped. Every decision (SLOW, GPS / "~N% est." labels, banners and when they can be tapped, which buttons exist)
/// is made in CorckieCore (`LiveScreenDriver`, unit tested); this view only draws the result.
struct LiveRideView: View {
    struct Preview {
        var screen: LiveScreenState
        var path: LivePath
        var position: LivePath.Coord?
    }

    var preview: Preview?

    @State private var hold = HoldToEnd()
    @State private var holdProgress = 0.0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var screen: LiveScreenState {
        if let p = preview { return p.screen }
        if let s = RecorderService.shared.liveScreen { return s }
        var d = LiveScreenDriver()
        return d.update(LiveInput(phase: .ready), at: 0)
    }

    private var path: LivePath {
        if let p = preview { return p.path }
        return RecorderService.shared.livePath
    }

    private var position: LivePath.Coord? {
        if let p = preview { return p.position }
        return RecorderService.shared.livePosition
    }

    var body: some View {
        let s = screen
        ZStack {
            mapView(s)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                topArea(s)
                Spacer()
                tiles(s)
                controls(s)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .interactiveDismissDisabled(true)
        .onReceive(ticker) { _ in tickHold() }
        .onChange(of: position?.lat) { _, _ in follow() }
        .screen("Live ride")
    }

    // MARK: Map

    private func mapView(_ s: LiveScreenState) -> some View {
        Map(position: $camera, interactionModes: []) {
            ForEach(Array(path.segments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: seg.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(Self.color(seg.bucket),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: seg.dashed ? [2, 10] : []))
            }
            if let p = position {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)) {
                    // M2-08: hollow while the dot moves by wheel distance (no GPS, known route)
                    Circle()
                        .fill(s.dotHollow ? Color.white.opacity(0.6) : (s.dotGreyed ? Color.gray : Color.blue))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(s.dotHollow ? Color.blue : Color.white, lineWidth: 3))
                }
            }
            if position == nil {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    private func follow() {
        guard preview == nil, let p = position else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), distance: 700))
        }
    }

    static func color(_ bucket: Int) -> Color {
        let colors: [Color] = [Color(red: 0.55, green: 0.85, blue: 0.55), .green, .yellow, .orange, .red]
        return colors[min(max(bucket, 0), colors.count - 1)]
    }

    // MARK: Top: banner, chips, starting dot

    private func topArea(_ s: LiveScreenState) -> some View {
        VStack(spacing: 8) {
            if let text = s.bannerText {
                banner(s, text)
            }
            HStack(spacing: 8) {
                if s.tiles.showStartingDot {
                    chip("starting\u{2026}", dot: .orange)
                }
                ForEach(Array(s.chips.enumerated()), id: \.offset) { _, c in
                    chip(c == .noGps ? "No GPS" : "Offline map", dot: nil)
                }
            }
            if let a = s.arrival {
                // M2-06 arrival strip (M28); under the banner, never over the speed and battery tiles
                Text(a.text)
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel(a.text)
            }
        }
    }

    private func chip(_ text: String, dot: Color?) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 10, height: 10) }
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func banner(_ s: LiveScreenState, _ text: String) -> some View {
        let tappable = s.banner?.tappable ?? false
        let hot = s.banner?.banner == .veryHot || s.banner?.banner == .hot
        let tint: Color? = hot ? Color.red : (s.bannerIsSameRide ? nil : Color.orange)
        return GlassCard(tint: tint) {
            HStack(spacing: 12) {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.leading)
                if s.bannerIsSameRide && tappable {
                    Spacer(minLength: 8)
                    Button("Yes") { RecorderService.shared.answerSameRide(true) }
                        .buttonStyle(.borderedProminent)
                    Button("No") { RecorderService.shared.answerSameRide(false) }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if tappable && !s.bannerIsSameRide { RecorderService.shared.tapBanner() }
        }
    }

    // MARK: Tiles

    private func tiles(_ s: LiveScreenState) -> some View {
        let t = s.tiles
        let batteryNumber: String = {
            guard let b = t.batteryPct else { return "\u{2013}" }
            return (t.batteryEstimated ? "~" : "") + "\(b)%"
        }()
        return VStack(spacing: 12) {
            GlassCard(tint: t.slow ? Color.red : nil) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t.speedKmh.map { String($0) } ?? "\u{2013}")
                        .font(.system(size: 112, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(t.slow ? Color.red : (t.speedGreyed ? Color.secondary : Color.primary))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("km/h").font(.title3).foregroundStyle(.secondary)
                        if let label = t.speedLabel {
                            Text(label)
                                .font(.headline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                        }
                        if let slow = t.slowText {
                            Text(slow)
                                .font(.system(size: 34, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(batteryNumber)
                            .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                        if t.batteryEstimated {
                            Text("est.").font(.headline).foregroundStyle(.secondary)
                        }
                    }
                }
                if s.showClock {
                    GlassCard {
                        Text(s.clockText)
                            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private func controls(_ s: LiveScreenState) -> some View {
        if s.canClose {
            VStack(spacing: 10) {
                Text("Ready \u{00B7} the ride starts when you move")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                Button("Close") { RecorderService.shared.closeReady() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            HStack(spacing: 24) {
                if s.showNotRiding {
                    Button("Not riding") { RecorderService.shared.press(.notRidingPressed) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if s.showHoldToEnd {
                    holdButton
                }
            }
        }
    }

    /// A tap does nothing; holding for a second ends the ride (T19).
    private var holdButton: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.ultraThinMaterial).frame(width: 84, height: 84)
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 84, height: 84)
                Image(systemName: "stop.fill").font(.system(size: 30)).foregroundStyle(Color.red)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if hold.startedAt == nil { hold.begin(at: Date().timeIntervalSince1970) }
                    }
                    .onEnded { _ in
                        hold.cancel()
                        holdProgress = 0
                    }
            )
            Text("Hold to end").font(.footnote.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hold to end the ride")
    }

    private func tickHold() {
        guard hold.startedAt != nil else { return }
        let now = Date().timeIntervalSince1970
        holdProgress = hold.progress(at: now)
        if hold.completed(at: now) {
            hold.cancel()
            holdProgress = 0
            RecorderService.shared.press(.endHeld)
        }
    }
}

/// Made-up live screens for the CI ui-shots (`-uiShot live-riding` and so on): the same driver as the real view.
enum LivePreview {
    static func make(_ name: String) -> LiveRideView.Preview? {
        guard name.hasPrefix("live-") else { return nil }
        let lat = 40.0
        let lon = -75.0
        var input = LiveInput(scooterSpeedKmh: 27, scooterBatteryPct: 82, phase: .riding, lat: lat, lon: lon, rideElapsedS: 754)
        var dashedFrom = 1000
        switch name {
        case "live-ready":
            input = LiveInput(scooterSpeedKmh: 0, scooterBatteryPct: 91, phase: .ready, lat: lat, lon: lon)
        case "live-starting":
            input = LiveInput(scooterSpeedKmh: 3, scooterBatteryPct: 91, starting: true, phase: .starting, lat: lat, lon: lon, rideElapsedS: 4)
        case "live-slow":
            input.scooterSpeedKmh = 46
        case "live-gps", "live-slowgps":
            input = LiveInput(gpsSpeedKmh: name == "live-slowgps" ? 47 : 31, scooterLinked: false, scooterBatteryPct: 64,
                              estimatedBatteryPct: 61, phase: .riding, phoneMode: true, lat: lat, lon: lon, rideElapsedS: 900)
            dashedFrom = 22
        case "live-nogps":
            input.secondsWithoutGps = 14
        case "live-offline":
            input.mapOffline = true
        case "live-banner":
            input.scooterTempC = 92
        case "live-sameride":
            input.phase = .starting
            input.starting = true
            input.scooterSpeedKmh = 0
            input.sameRideOffered = true
            input.rideElapsedS = 6
        default:
            break
        }
        var driver = LiveScreenDriver()
        var clock = 0.0
        if name == "live-arrival" || name == "live-routegps" || name == "live-return" {
            // M2-06 / M2-08: a made-up straight route 2.7 km long (no real place), followed from 1.1 km
            clock = Date().timeIntervalSince1970
            let points = (0..<31).map { GeoPoint(lat: lat - 0.012 + Double($0) * 0.0009, lon: lon) }
            driver.follow(RouteFollower(destinationName: "Work", path: points, todayS: 540), utcOffsetMin: TimeZone.current.secondsFromGMT() / 60,
                          returnWarning: name == "live-return" ? "Battery 20%: enough for Work, not for the way back." : nil)
            input.rideDistanceM = 1_100
            if name == "live-routegps" {
                _ = driver.update(input, at: clock - 20)
                input.secondsWithoutGps = 15
                input.rideDistanceM = 1_500
            }
        }
        let screen = driver.update(input, at: clock)
        var path = LivePath()
        for i in 0..<40 {
            path.add(lat: lat - 0.0008 + Double(i) * 0.00004, lon: lon - 0.0008 + Double(i) * 0.00004 + 0.0002 * sin(Double(i) / 5),
                     speedKmh: Double(i), dashed: i >= dashedFrom)
        }
        return LiveRideView.Preview(screen: screen, path: path, position: screen.dotOverride ?? LivePath.Coord(lat: lat, lon: lon))
    }
}
