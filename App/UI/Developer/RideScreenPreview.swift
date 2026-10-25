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
        let speed = max(0, 22 + 8 * sin(t / 25))
        let p = point(at: t)
        var input = LiveInput(scooterSpeedKmh: phone ? nil : speed, gpsSpeedKmh: speed, scooterLinked: !phone,
                              scooterBatteryPct: phone ? nil : battery, estimatedBatteryPct: phone ? battery : nil,
                              phase: .riding, lat: p.lat, lon: p.lon, rideElapsedS: t)
        input.phoneMode = phone
        input.scooterTempC = hot ? 92 : 45
        input.rideDistanceM = t * 6
        let screen = driver.update(input, at: Date().timeIntervalSince1970)
        path.add(lat: p.lat, lon: p.lon, speedKmh: speed, dashed: phone)
        preview = LiveRideView.Preview(screen: screen, path: path, position: screen.dotOverride ?? LivePath.Coord(lat: p.lat, lon: p.lon))
    }
}

private struct NightIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.liveDark() } else { content }
    }
}
