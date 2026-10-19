import CorckieCore
import SwiftUI

/// UI_PLAN 1.6 / F-15 theme v2: the page behind the tab screens.
/// - Default: the plain theme page (white / #121212). Owner answer 2: only Home keeps a map behind it.
/// - `MapBackdrop(map: true)` (Home): the map muted with a slight warm tint. On the phone a real Apple map snapshot
///   (`MapSnapshotStore`, B14), almost without colour under a white / dark veil and a sand wash; in the CI shots and previews a
///   drawn, made-up street pattern in the same muted sand tones (no MapKit, no network, no location, not a real area).
/// - Sunlight mode: always the plain page (high contrast). Ride and route maps are real `Map`s and stay normal (not this view).
struct MapBackdrop: View {
    var map = false
    /// V17: the last parked spot as a pin on the map picture (Home only)
    var parked: ParkedSpot?
    /// ui-shots: a made-up pin position as a fraction of the screen (the drawn map has no coordinates)
    var parkedPreview: CGPoint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sunlight) private var sunlight
    private let store = MapSnapshotStore.shared

    var body: some View {
        base.overlay { pinLayer }
    }

    @ViewBuilder private var pinLayer: some View {
        if map, !sunlight, parked != nil || parkedPreview != nil {
            GeometryReader { geo in
                if let p = pinPoint(in: geo.size) {
                    ParkedPinMark().position(x: p.x, y: p.y - 17)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func pinPoint(in size: CGSize) -> CGPoint? {
        if let f = parkedPreview { return CGPoint(x: f.x * size.width, y: f.y * size.height) }
        guard let spot = parked, store.image(dark: scheme == .dark) != nil, let f = store.pinFraction(lat: spot.lat, lon: spot.lon) else { return nil }
        let aspect = Double(MapSnapshotStore.pictureSize.width / MapSnapshotStore.pictureSize.height)
        let p = ParkedPin.inFilledView(f, imageAspect: aspect, viewWidth: Double(size.width), viewHeight: Double(size.height))
        guard p.x >= 0, p.x <= Double(size.width), p.y >= 0, p.y <= Double(size.height) else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    @ViewBuilder private var base: some View {
        if sunlight || !map {
            Theme.background
        } else {
            let dark = scheme == .dark
            if let image = store.image(dark: dark) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .saturation(0.15)
                    .blur(radius: 3)
                    .overlay(Theme.background.opacity(dark ? 0.62 : 0.72))
                    .overlay(Theme.chip.opacity(dark ? 0.10 : 0.30))
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, dark: dark)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private static func draw(_ context: GraphicsContext, size: CGSize, dark: Bool) {
        var ctx = context
        let w = size.width
        let h = size.height
        // F-15: muted, slightly warm (sand) tones; dark = neutral greys
        let land = dark ? Color(white: 0.085) : Color(red: 0.992, green: 0.984, blue: 0.969)
        let block = dark ? Color(white: 0.11) : Color(red: 0.972, green: 0.953, blue: 0.922)
        let water = dark ? Color(white: 0.10) : Color(red: 0.957, green: 0.937, blue: 0.906)
        let park = dark ? Color(white: 0.115) : Color(red: 0.953, green: 0.929, blue: 0.890)
        let road = dark ? Color(white: 0.14) : Color.white
        let avenue = dark ? Color(white: 0.16) : Color(red: 0.953, green: 0.906, blue: 0.827)

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(land))

        // blocks on a 76 pt grid, a few left out for variety
        let step: CGFloat = 76
        var row = 0
        var y: CGFloat = 8
        while y < h {
            var col = 0
            var x: CGFloat = 6
            while x < w {
                if (row * 7 + col * 3) % 5 != 0 {
                    let r = CGRect(x: x, y: y, width: step - 12, height: step - 12)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(block))
                }
                x += step
                col += 1
            }
            y += step
            row += 1
        }

        // streets between the blocks
        var gx: CGFloat = 0
        while gx < w {
            var line = Path()
            line.move(to: CGPoint(x: gx, y: 0))
            line.addLine(to: CGPoint(x: gx, y: h))
            ctx.stroke(line, with: .color(road), lineWidth: 4)
            gx += step
        }
        var gy: CGFloat = 2
        while gy < h {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: gy))
            line.addLine(to: CGPoint(x: w, y: gy))
            ctx.stroke(line, with: .color(road), lineWidth: 4)
            gy += step
        }

        // park
        ctx.fill(Path(roundedRect: CGRect(x: w * 0.06, y: h * 0.58, width: w * 0.30, height: h * 0.16), cornerRadius: 14), with: .color(park))
        ctx.fill(Path(roundedRect: CGRect(x: w * 0.58, y: h * 0.27, width: w * 0.22, height: h * 0.14), cornerRadius: 14), with: .color(park))

        // a diagonal avenue
        var avenuePath = Path()
        avenuePath.move(to: CGPoint(x: w * 0.05, y: h * 1.02))
        avenuePath.addLine(to: CGPoint(x: w * 1.05, y: h * 0.42))
        ctx.stroke(avenuePath, with: .color(avenue), lineWidth: 16)

        // water along the top
        var waterPath = Path()
        waterPath.move(to: CGPoint(x: 0, y: 0))
        waterPath.addLine(to: CGPoint(x: w, y: 0))
        waterPath.addLine(to: CGPoint(x: w, y: h * 0.05))
        waterPath.addQuadCurve(to: CGPoint(x: 0, y: h * 0.10), control: CGPoint(x: w * 0.45, y: h * 0.02))
        waterPath.closeSubpath()
        ctx.fill(waterPath, with: .color(water))
    }
}

/// V17: the pin for the parked scooter on Home's map: a small orange disc with the scooter, and a point down to the spot.
struct ParkedPinMark: View {
    var body: some View {
        VStack(spacing: -2) {
            Image(systemName: "scooter")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 34, height: 34)
                .background(Theme.accent, in: Circle())
                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Parked scooter")
    }
}
