import SwiftUI

/// UI_PLAN 1.6: a static, made-up street map behind the tab screens (land, blocks, park, water, roads, a veil).
/// B14: on the phone a real Apple map snapshot (`MapSnapshotStore`) replaces it. This drawn one stays for the CI shots and previews:
/// no MapKit, no network, no location, the same picture in every CI shot. It is a generic
/// pattern, not a real area. In sunlight mode it is plain (a solid page), like the glass cards.
struct MapBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sunlight) private var sunlight
    private let store = MapSnapshotStore.shared

    var body: some View {
        if sunlight {
            Color(.systemBackground)
        } else {
            let dark = scheme == .dark
            if let image = store.image(dark: dark) {
                // B14: the real map as a picture, blurred under the glass; same veil as the drawn one
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 6)
                    .overlay(Color(.systemBackground).opacity(dark ? 0.45 : 0.55))
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, dark: dark)
                }
                .overlay(Color(.systemBackground).opacity(dark ? 0.5 : 0.66))
                .accessibilityHidden(true)
            }
        }
    }

    private static func draw(_ context: GraphicsContext, size: CGSize, dark: Bool) {
        var ctx = context
        let w = size.width
        let h = size.height
        let land = dark ? Color(red: 0.11, green: 0.13, blue: 0.12) : Color(red: 0.90, green: 0.93, blue: 0.89)
        let block = dark ? Color(red: 0.14, green: 0.16, blue: 0.15) : Color(red: 0.93, green: 0.95, blue: 0.92)
        let water = dark ? Color(red: 0.10, green: 0.17, blue: 0.22) : Color(red: 0.78, green: 0.87, blue: 0.92)
        let park = dark ? Color(red: 0.12, green: 0.21, blue: 0.14) : Color(red: 0.80, green: 0.90, blue: 0.79)
        let road = dark ? Color(red: 0.20, green: 0.22, blue: 0.21) : Color.white.opacity(0.85)
        let avenue = dark ? Color(red: 0.26, green: 0.25, blue: 0.19) : Color(red: 0.96, green: 0.94, blue: 0.84)

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
