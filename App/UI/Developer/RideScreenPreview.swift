import CorckieCore
import SwiftUI

/// F-37 (owner 22 Oct, note 6): Settings → Developer → Ride screen preview. The REAL live ride screen, full screen, playing a made-up
/// ride (speed, battery, arrival line, map moving) with a "Preview" badge. It never records, never touches the recorder or real data:
/// the screen is driven through its preview input only, and its own buttons are switched off. Hidden ⋯: pause / play, events
/// (battery 20 / 15 / 10 %, Motor hot, phone took over) and scenarios (with / without destination, day / night).
struct RideScreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var t = 0.0
    @State private var playing = true
    @State private var withDestination = true
    @State private var night = false
    @State private var battery = 78.0
    @State private var hot = false
    @State private var phone = false
    @State private var driver = LiveScreenDriver()
    @State private var path = LivePath()
    @State private var preview: LiveRideView.Preview?
    /// V09 in the preview: the real director on the made-up ride; events change its inputs; it speaks (the only sound of the preview)
    @State private var v09 = V09Director()
    @State private var arrivalLine = ArrivalLineTracker()
    @State private var tempC = 45.0
    @State private var usualPctPerKm = 2.0
    @State private var usualTripS: Double?
    @State private var stopUntil = -1.0
    @State private var powerLimit: Int?
    @State private var said: String?
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// A made-up loop (not a real place)
    private static let centre = (lat: 40.0, lon: -75.0)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let preview {
                LiveRideView(preview: preview)
                    .allowsHitTesting(false)   // never presses the real recorder
                    .modifier(NightIf(on: night))
            } else {
                Theme.background.ignoresSafeArea()
            }
            HStack(spacing: 8) {
                Text("Preview").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.purple, in: Capsule())
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.5))
                }
                .accessibilityLabel("Preview controls")
            }
            .padding(.top, 54)
            .padding(.trailing, 16)
            if let said {
                VStack {
                    Spacer()
                    Text(said).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(10).background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16).padding(.bottom, 140)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: restart)
        .onReceive(ticker) { _ in if playing { step(0.5) } }
        .screen("Ride screen preview")
    }

    @ViewBuilder private var menuItems: some View {
        Button(playing ? "Pause" : "Play") { playing.toggle() }
        Menu("Events") {
            Button("Battery 20 %") { battery = 20 }
            Button("Battery 15 %") { battery = 15 }
            Button("Battery 10 %") { battery = 10 }
            Button(hot ? "Motor cool again" : "Motor hot") { hot.toggle() }
            Button(phone ? "Scooter back" : "Phone took over") { phone.toggle() }
        }
        Menu("Voice (V09)") {
            Button("Using more than usual (waits for a stop)") { usualPctPerKm = 0.5 }
            Button("Stop at a light (20 s)") { stopUntil = t + 80 }
            Button("Engine hot 86 \u{00B0}C") { tempC = 86 }
            Button("Engine overheating 94 \u{00B0}C") { tempC = 94 }
            Button("Engine cool") { tempC = 45 }
            Button("Sharp drop") { battery = max(5, battery - 9) }
            Button("Running late") { usualTripS = 60 }
            Button("Power limit coming") { powerLimit = max(1, Int(battery) - 2) }
            Button("Play every message once") { RideVoice.shared.playAllV09() }
        }
        Menu("Scenario") {
            Button(withDestination ? "No destination" : "Riding to Uni") { withDestination.toggle(); restart() }
            Button(night ? "Day" : "Night") { night.toggle() }
        }
        Button("Close", role: .destructive) { dismiss() }
    }

    private func point(at s: Double) -> (lat: Double, lon: Double) {
        let a = s / 600 * 2 * Double.pi
        return (Self.centre.lat + 0.012 * sin(a), Self.centre.lon + 0.016 * (1 - cos(a)))
    }

    private func restart() {
        t = 0
        battery = 78
        driver = LiveScreenDriver()
        v09 = V09Director()
        arrivalLine = ArrivalLineTracker()
        tempC = 45
        usualPctPerKm = 2
        usualTripS = nil
        stopUntil = -1
        powerLimit = nil
        said = nil
        path = LivePath()
        if withDestination {
            let route = (0..<61).map { i -> GeoPoint in let p = point(at: Double(i) * 10); return GeoPoint(lat: p.lat, lon: p.lon) }
            driver.follow(RouteFollower(destinationName: "Uni", path: route, todayS: 900), utcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
        }
        step(0)
    }

    private func step(_ dt: Double) {
        t += dt * 4                       // 4× real time
        if t > 600 { restart(); return }
        battery = max(5, battery - dt * 4 * 0.02)
        let speed = t < stopUntil ? 0 : max(0, 22 + 8 * sin(t / 25))
        let p = point(at: t)
        var input = LiveInput(scooterSpeedKmh: phone ? nil : speed, gpsSpeedKmh: speed, scooterLinked: !phone,
                              scooterBatteryPct: phone ? nil : battery, estimatedBatteryPct: phone ? battery : nil,
                              phase: .riding, lat: p.lat, lon: p.lon, rideElapsedS: t)
        input.phoneMode = phone
        input.scooterTempC = hot ? 92 : tempC
        input.rideDistanceM = t * 6
        let screen = driver.update(input, at: Date().timeIntervalSince1970)
        if dt > 0 { voice(input, screen, speed: speed) }
        path.add(lat: p.lat, lon: p.lon, speedKmh: speed, dashed: phone)
        preview = LiveRideView.Preview(screen: screen, path: path, position: screen.dotOverride ?? LivePath.Coord(lat: p.lat, lon: p.lon))
    }
}

extension RideScreenPreview {
    /// V09 on the made-up ride, at preview time (4×): urgent lines at once, the rest at the stop or a straight stretch
    fileprivate func voice(_ input: LiveInput, _ screen: LiveScreenState, speed: Double) {
        let v = V09Input(t: t, pct: input.scooterBatteryPct, tempC: input.scooterTempC, rideKm: (input.rideDistanceM ?? 0) / 1000, speedKmh: speed,
                         courseDeg: (t / 600 * 360).truncatingRemainder(dividingBy: 360), usualPctPerKm: usualPctPerKm,
                         routeKm: screen.routeProgress?.routeKm, alongKm: screen.routeProgress?.alongKm, usualTripS: usualTripS,
                         elapsedS: t, remainingS: screen.remainingS, powerLimitPct: powerLimit, recordingProblem: phone)
        var lines = v09.update(v)
        if screen.arrived, let m = arrivalLine.arrived(place: withDestination ? "Uni" : nil, pct: input.scooterBatteryPct) { lines.append(m) }
        for m in lines {
            SoundPlayer.shared.say(m.line)
            said = (m.urgent ? "Now: " : "At a good moment: ") + m.line
        }
    }
}

private struct NightIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.liveDark() } else { content }
    }
}
