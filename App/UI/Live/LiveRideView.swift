import CorckieCore
import MapKit
import SwiftUI

/// M1-12 live ride view: a full-screen map, glass tiles, no tab bar and no navigation. It is shown as a full-screen
/// cover (see `RootView`) while a ride is on, or in "Ready" (D2) when the "Going for a ride?" notification was
/// tapped. Every decision (GPS / "~N% est." labels, banners and when they can be tapped, which buttons exist)
/// is made in CorckieCore (`LiveScreenDriver`, unit tested); this view only draws the result.
struct LiveRideView: View {
    struct Preview {
        var screen: LiveScreenState
        var path: LivePath
        var position: LivePath.Coord?
    }

    var preview: Preview?
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hold = HoldToEnd()
    @State private var answerTap = 0
    @State private var holdActive = false
    @State private var holdProgress = 0.0
    /// F-19: a light tick at each quarter of the fill, a strong tap when the ride ends
    @State private var holdTicks = 0
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var track = LiveCameraTrack()
    @State private var tilesTop: CGFloat?
    @State private var lastHeading: Double?
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
                // the open map above the tiles: where it ends is where the dot is kept clear of the tiles (F-10 fix)
                Color.clear
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("liveRide")).maxY }) { tilesTop = $0 + 12 }
                tiles(s)
                controls(s)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .coordinateSpace(name: "liveRide")
        .interactiveDismissDisabled(true)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)       // the numbers keep their size; the rest does not outgrow the screen (M6-04)
        .onChange(of: s.bannerText) { _, text in
            // VoiceOver: say a new banner (motor hot ...) out loud
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onReceive(ticker) { _ in tickHold() }
        .onChange(of: position) { _, _ in follow() }
        .screen("Live ride")
    }

    // MARK: Map

    /// F-10: with motion on, the Map hangs off the bottom of the screen and its centre, where the camera puts the rider's dot, sits just above
    /// the speed tile (24 pt clear of it), measured from the real tile layout: the map is twice as tall as that distance, so the camera
    /// centre is exactly there and most of the visible map shows the road ahead. The dot is drawn at that same spot.
    private var lookAhead: Bool { !reduceMotion }
    private static let dotClearance: CGFloat = 34      // 24 pt gap + the dot's radius

    private func mapView(_ s: LiveScreenState) -> some View {
        GeometryReader { geo in
            let top = geo.frame(in: .named("liveRide")).minY
            let fallback = geo.size.height * 0.62
            let measured = tilesTop.map { $0 - top } ?? fallback
            let usable = measured > 150 ? measured : fallback      // a tile position not measured yet (0) is not used
            let dotY = CGFloat(LiveCameraTrack.dotY(tilesTop: Double(usable), clearance: Double(Self.dotClearance), minY: 80))
            let mapHeight = max(dotY * 2, geo.size.height)
            ZStack(alignment: .top) {
                mapContent(s)
                    .frame(width: geo.size.width, height: lookAhead ? mapHeight : geo.size.height)
                    .offset(y: lookAhead ? dotY - mapHeight / 2 : 0)      // centre stays at the dot even when the map must cover the whole screen
                if lookAhead, position != nil {
                    dotView(s).position(x: geo.size.width / 2, y: dotY)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func dotView(_ s: LiveScreenState) -> some View {
        // M2-08: hollow while the dot moves by wheel distance (no GPS, known route)
        Circle()
            .fill(s.dotHollow ? Color.white.opacity(0.6) : (s.dotGreyed ? Color.gray : Theme.accent))
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(s.dotHollow ? Theme.accent : Color.white, lineWidth: 3))
    }

    private func mapContent(_ s: LiveScreenState) -> some View {
        Map(position: $camera, interactionModes: []) {
            ForEach(Array(LiveGradient.stretches(path).enumerated()), id: \.offset) { _, st in
                MapPolyline(coordinates: st.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(GradientPath.color(.speed, st.value),
                            style: StrokeStyle(lineWidth: sunlight ? 9 : 6, lineCap: .round, lineJoin: .round, dash: st.dashed ? [2, 10] : []))
            }
            if let p = position, !lookAhead {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)) { dotView(s) }
            }
            if position == nil {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Map, following your position")
        .onAppear { showPreviewCamera() }
    }

    /// ui-shots: the made-up position, turned the way the made-up path runs
    private func showPreviewCamera() {
        guard let p = preview?.position else { return }
        camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), distance: 700,
                                   heading: lookAhead ? 40 : 0))
    }

    /// B22 / F-10: every fix glides the camera (and with it the dot) in a straight line over the fix interval to the position predicted
    /// for the next fix; the map turns with the course. No timers: one animation per fix. Reduce Motion: north-up, no animation.
    private func follow() {
        guard preview == nil, let p = position else { return }
        let speed = screen.tiles.speedKmh.map(Double.init)
        let u = track.fix(lat: p.lat, lon: p.lon, atS: Date().timeIntervalSince1970, speedKmh: speed)
        if reduceMotion {
            camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), distance: 700))
            return
        }
        let heading = LiveCameraTrack.shortestHeading(from: lastHeading, to: u.headingDeg ?? lastHeading ?? 0)
        lastHeading = heading
        let target = MapCameraPosition.camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: u.centerLat, longitude: u.centerLon),
            distance: LiveCameraTrack.cameraDistanceM(speedKmh: speed ?? 0),
            heading: heading))
        withAnimation(.linear(duration: u.durationS)) { camera = target }
    }

    static func color(_ bucket: Int) -> Color {
        // M5-06: the colour-blind friendly speed colours (blue to vermillion, no red / green pair)
        let colors: [Color] = DisplaySettings.colourBlind
            ? SpeedPalette.colourBlindHex.map { Color(hex: $0) }
            : [Color(red: 0.55, green: 0.85, blue: 0.55), .green, .yellow, .orange, .red]
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
                    chip(c == .noGps ? "No GPS" : "Offline map", dot: nil, symbol: c == .noGps ? "location.slash" : "map")
                }
            }
            if let a = s.arrival {
                // M2-06 arrival strip (M28); under the banner, never over the speed and battery tiles
                Label(a.short, systemImage: "mappin.and.ellipse")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .sunPanel(Capsule())
                    .accessibilityLabel(a.text)
            }
        }
    }

    private func chip(_ text: String, dot: Color?, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 10, height: 10) }
            if let symbol { Image(systemName: symbol).font(.subheadline.weight(.semibold)).accessibilityHidden(true) }
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sunPanel(Capsule())
    }

    /// P-4: the only banners are the motor heat and plain data states (`LiveAlerts`); a tap takes one away below 5 km/h.
    private func banner(_ s: LiveScreenState, _ text: String) -> some View {
        let tappable = s.banner?.tappable ?? false
        let hot = s.banner?.banner == .veryHot || s.banner?.banner == .hot
        let tint: Color = hot ? Color.red : Color.orange
        return GlassCard(tint: tint) {
            HStack(spacing: 12) {
                if hot { Image(systemName: "thermometer.medium").font(.title3.weight(.semibold)).accessibilityHidden(true) }
                Text(text)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if tappable { RecorderService.shared.tapBanner() }
        }
    }

    // MARK: Tiles

    /// B21: font sizes of the live tiles. Safety guards (LiveViewGuardTests): speed >= 76 pt, battery and ride time >= 60 pt.
    static let speedPt: CGFloat = 88
    static let tilePt: CGFloat = 60

    private func tiles(_ s: LiveScreenState) -> some View {
        VStack(spacing: 12) {
            speedTile(s)
            HStack(spacing: 12) {
                batteryTile(s)
                if s.showClock { clockTile(s) }
            }
        }
    }

    /// P-4: the speed is shown plainly, whatever it is (no red tile, no warning badge)
    private func speedTile(_ s: LiveScreenState) -> some View {
        let t = s.tiles
        let speedLabel = "Speed " + (t.speedKmh.map { "\($0) kilometres per hour" } ?? "unknown") + (t.speedLabel.map { ", " + $0 } ?? "")
        return GlassCard {
            HStack(alignment: .firstTextBaseline) {
                Text(t.speedKmh.map { String($0) } ?? "\u{2013}")
                    .font(.system(size: Self.speedPt, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(t.speedGreyed ? Color.secondary : Color.primary)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("km/h").font(.title3).foregroundStyle(.secondary)
                    if let label = t.speedLabel {
                        Text(label)
                            .font(.headline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .sunPanel(Capsule(), thin: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speedLabel)
    }

    /// battery and ride time share one look: same font, centred, a small label under the number (B21)
    private func smallTile(_ number: String, label: String) -> some View {
        GlassCard {
            VStack(spacing: 0) {
                Text(number)
                    .font(.system(size: Self.tilePt, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)       // only for "~100%" or a ride past an hour; normally the full size
                Text(label).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func batteryTile(_ s: LiveScreenState) -> some View {
        let t = s.tiles
        let number: String = {
            guard let b = t.batteryPct else { return "\u{2013}" }
            return (t.batteryEstimated ? "~" : "") + "\(b)%"
        }()
        let spoken = "Battery " + (t.batteryPct.map { "\($0) percent" + (t.batteryEstimated ? ", estimated" : "") } ?? "unknown")
        return smallTile(number, label: t.batteryEstimated ? "battery \u{00B7} est." : "battery")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }

    private func clockTile(_ s: LiveScreenState) -> some View {
        smallTile(s.clockText, label: "ride time")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ride time " + s.clockText)
    }

    // MARK: Controls

    @ViewBuilder private func controls(_ s: LiveScreenState) -> some View {
        if s.canClose {
            VStack(spacing: 10) {
                Label("Ready", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .sunPanel(Capsule())
                Button("Close") { RecorderService.shared.closeReady() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            HStack(spacing: 24) {
                if s.showNotRiding {
                    Button("Not riding") { answerTap += 1; RecorderService.shared.press(.notRidingPressed) }
                        .sensoryFeedback(.impact(weight: .medium), trigger: answerTap)
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
                Color.clear.frame(width: 84, height: 84).sunPanel(Circle())
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
                        if hold.startedAt == nil { hold.begin(at: Date().timeIntervalSince1970); holdActive = true }
                    }
                    .onEnded { _ in
                        hold.cancel()
                        holdActive = false
                        holdProgress = 0
                        holdTicks = 0
                    }
            )
            Text("Hold to end").font(.footnote.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .sensoryFeedback(trigger: holdActive) { _, new in new ? .impact(weight: .light) : nil }
        .accessibilityLabel("Hold to end the ride")
        .accessibilityHint("Press and hold for one second")
        .accessibilityAddTraits([.isButton, .allowsDirectInteraction])      // VoiceOver: the hold works by touching it directly
    }

    private func tickHold() {
        guard hold.startedAt != nil else { return }
        let now = Date().timeIntervalSince1970
        holdProgress = hold.progress(at: now)
        let quarter = Int(holdProgress * 4)
        if quarter > holdTicks, quarter < 4 {
            holdTicks = quarter
            Haptics.light()
        }
        if hold.completed(at: now) {
            hold.cancel()
            holdProgress = 0
            holdActive = false
            holdTicks = 0
            Haptics.strong()
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
        case "live-fast":
            input.scooterSpeedKmh = 52     // P-4: shown plainly, no red tile
        case "live-gps":
            input = LiveInput(gpsSpeedKmh: 31, scooterLinked: false, scooterBatteryPct: 64,
                              estimatedBatteryPct: 61, phase: .riding, phoneMode: true, lat: lat, lon: lon, rideElapsedS: 900)
            dashedFrom = 22
        case "live-nogps":
            input.secondsWithoutGps = 14
        case "live-offline":
            input.mapOffline = true
        case "live-banner":
            input.scooterTempC = 92
        default:
            break
        }
        var driver = LiveScreenDriver()
        var clock = 0.0
        if name == "live-arrival" || name == "live-routegps" {
            // M2-06 / M2-08: a made-up straight route 2.7 km long (no real place), followed from 1.1 km
            clock = Date().timeIntervalSince1970
            let points = (0..<31).map { GeoPoint(lat: lat - 0.012 + Double($0) * 0.0009, lon: lon) }
            driver.follow(RouteFollower(destinationName: "Work", path: points, todayS: 540), utcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
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
