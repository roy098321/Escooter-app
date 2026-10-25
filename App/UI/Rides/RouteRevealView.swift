import CorckieCore
import MapKit
import SwiftUI

/// B53: the route drawing itself after a ride, smooth at the display's rate (60/120 Hz): one canvas over the map follows a
/// `TimelineView(.animation)`, the stretches are placed with the map's own projection and the front stretch is drawn in part.
/// Nothing is added to the map per step; when it is done the real gradient line (B59) takes over.
struct RouteRevealView: View {
    let stretches: [ValueStretch]
    let ramp: GradientRamp
    let start: Date
    let proxy: MapProxy
    var width: CGFloat = 5

    var body: some View {
        let ends = RouteReveal.ends(stretches)
        TimelineView(.animation) { timeline in
            let progress = RouteReveal.progress(elapsedS: timeline.date.timeIntervalSince(start))
            Canvas { context, _ in
                let shown = RouteReveal.visible(ends: ends, progress: progress)
                let count = min(stretches.count, shown.whole + (shown.partial > 0 ? 1 : 0))
                for i in 0..<count {
                    let s = stretches[i]
                    guard let a = proxy.convert(CLLocationCoordinate2D(latitude: s.a.lat, longitude: s.a.lon), to: .local),
                          let b = proxy.convert(CLLocationCoordinate2D(latitude: s.b.lat, longitude: s.b.lon), to: .local) else { continue }
                    let f: CGFloat = i < shown.whole ? 1 : CGFloat(shown.partial)
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                    context.stroke(path, with: .color(GradientPath.color(ramp, s.value)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
