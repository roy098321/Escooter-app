import CoreImage
import CorckieCore
import SwiftUI
import UIKit
import Vision

/// F-26: the stick-figure line-art scooter (side view, facing right): two wheels, deck and neck, stem, bar and a fender. Drawn in a 400 x 392
/// box (the geometry of the owner's mock-stick) and scaled to whatever rect it gets; the stroke is set by the caller (11 units at 400 wide).
struct ScooterLineArt: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 400
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var p = Path()
        for cx in [CGFloat(72), 328] {
            p.addEllipse(in: CGRect(x: rect.minX + (cx - 50) * k, y: rect.minY + (326 - 50) * k, width: 100 * k, height: 100 * k))
        }
        p.move(to: pt(72, 326)); p.addLine(to: pt(112, 290)); p.addLine(to: pt(262, 290)); p.addLine(to: pt(300, 196))
        p.move(to: pt(328, 326)); p.addLine(to: pt(276, 40))
        p.move(to: pt(240, 40)); p.addLine(to: pt(312, 40))
        p.move(to: pt(30, 268)); p.addQuadCurve(to: pt(96, 262), control: pt(60, 250))
        return p
    }
}

/// the two wheel hubs (small filled dots)
struct ScooterHubs: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 400
        var p = Path()
        for cx in [CGFloat(72), 328] {
            p.addEllipse(in: CGRect(x: rect.minX + (cx - 6) * k, y: rect.minY + (326 - 6) * k, width: 12 * k, height: 12 * k))
        }
        return p
    }
}

extension ScooterColour {
    var color: Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// F-26: the big card at the top of the Scooter tab. The scooter enters from the left edge, half inside, full card height; name, battery %,
/// the "when last connected" caption, the odometer pill and Connect sit on the right. With a photo, everything over it gets a dark halo.
struct ScooterHeroCard: View {
    let name: String
    let connected: Bool
    let pct: Int?
    let caption: String?
    let odometerKm: Double?
    let colour: ScooterColour
    let photo: ScooterPhotoStore.Loaded?
    let onConnect: () -> Void
    @State private var connectTap = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private let artSize = CGSize(width: 300, height: 294)

    init(name: String, connected: Bool, pct: Int?, caption: String?, odometerKm: Double?, colour: ScooterColour = .sand,
         photo: ScooterPhotoStore.Loaded? = nil, onConnect: @escaping () -> Void = {}) {
        self.name = name
        self.connected = connected
        self.pct = pct
        self.caption = caption
        self.odometerKm = odometerKm
        self.colour = colour
        self.photo = photo
        self.onConnect = onConnect
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            art
            HStack(spacing: 0) {
                Spacer(minLength: typeSize.isAccessibilitySize ? 60 : 150)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(connected ? Theme.ok : Theme.accent).frame(width: 9, height: 9)
                        Text(name).font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    HStack(spacing: 4) {
                        if !connected { Image(systemName: "clock").font(.footnote).foregroundStyle(.secondary) }
                        Text(pct.map { "\($0)%" } ?? "\u{2013}")
                            .scaledFont(52, weight: .semibold, mono: true, relativeTo: .largeTitle)
                            .minimumScaleFactor(0.6).lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(connected ? "Battery \(pct ?? 0)%" : "Battery \(pct ?? 0)%, \(caption ?? "")")
                    if !connected, let caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(3)
                    }
                    if let odometerKm {
                        InfoChip("gauge.with.dots.needle.67percent", String(format: "%.1f km", odometerKm), label: "Odometer").padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .halo(photo != nil)
            }
            .padding(.top, 24)
            .padding(.trailing, 20)
            if !connected {
                Button { connectTap += 1; onConnect() } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 62, height: 62)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .halo(photo != nil)
                .accessibilityLabel("Connect")
                .sensoryFeedback(.impact(weight: .medium), trigger: connectTap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
    }

    @ViewBuilder private var art: some View {
        if let photo {
            if photo.cutout {
                // a cut-out: full card height, exactly half of its width inside the card from the left edge
                let aspect = photo.image.size.height > 0 ? photo.image.size.width / photo.image.size.height : 1
                Image(uiImage: photo.image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: artSize.height * aspect, height: artSize.height)
                    .offset(x: -artSize.height * aspect / 2, y: 8)
                    .accessibilityHidden(true)
            } else {
                // no subject found: the whole photo, aspect-fill in the same left-half place
                Image(uiImage: photo.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: artSize.width, height: artSize.height)
                    .clipped()
                    .offset(x: -118, y: 8)
                    .accessibilityHidden(true)
            }
        } else {
            ZStack {
                ScooterLineArt().stroke(colour.color, style: StrokeStyle(lineWidth: 11 * artSize.width / 400, lineCap: .round, lineJoin: .round))
                ScooterHubs().fill(colour.color)
            }
            .frame(width: artSize.width, height: artSize.height)
            .offset(x: -118, y: 8)
            .accessibilityHidden(true)
        }
    }
}

private extension View {
    /// a soft dark outline and glow, so text and buttons read on any photo
    @ViewBuilder func halo(_ on: Bool) -> some View {
        if on {
            self.shadow(color: .black.opacity(0.85), radius: 1).shadow(color: .black.opacity(0.7), radius: 5)
        } else {
            self
        }
    }
}

/// F-26: the owner's own scooter photo, kept in Application Support only (P-2: never committed, never sent anywhere, not in backups).
/// A picture that already has transparency is kept as it is; otherwise Vision's foreground mask cuts the subject out; when it finds
/// none the whole photo is used.
enum ScooterPhotoStore {
    struct Loaded: @unchecked Sendable {
        var image: UIImage
        var cutout: Bool
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScooterHero", isDirectory: true)
    }
    private static var cutoutFile: URL { folder.appendingPathComponent("scooter-cutout.png") }
    private static var fullFile: URL { folder.appendingPathComponent("scooter-photo.jpg") }

    static func load() -> Loaded? {
        if let d = try? Data(contentsOf: cutoutFile), let i = UIImage(data: d) { return Loaded(image: i, cutout: true) }
        if let d = try? Data(contentsOf: fullFile), let i = UIImage(data: d) { return Loaded(image: i, cutout: false) }
        return nil
    }

    static func remove() {
        try? FileManager.default.removeItem(at: cutoutFile)
        try? FileManager.default.removeItem(at: fullFile)
    }

    /// Processes the picked picture (off the main thread) and stores it; returns what to show.
    static func store(_ data: Data) async -> Loaded? {
        await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let raw = UIImage(data: data), let image = normalized(raw, maxSide: 1600) else { return nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var dir = folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
                remove()
                if let result = hasTransparency(image) ? image : cutOut(image) {
                    guard let png = result.pngData() else { return nil }
                    try png.write(to: cutoutFile, options: .completeFileProtection)
                    return Loaded(image: result, cutout: true)
                }
                guard let jpg = image.jpegData(compressionQuality: 0.85) else { return nil }
                try jpg.write(to: fullFile, options: .completeFileProtection)
                return Loaded(image: image, cutout: false)
            } catch {
                return nil
            }
        }.value
    }

    /// redraw upright and no bigger than `maxSide`, keeping any alpha
    static func normalized(_ image: UIImage, maxSide: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// does any corner-sampled or edge pixel have alpha below 1 (a cut-out PNG)? Sampled on a small copy.
    static func hasTransparency(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var clear = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 250 { clear += 1 }
        return clear > (w * h) / 20      // at least 5 % of the picture is see-through
    }

    /// Vision foreground cut-out (iOS 17); nil when it finds no subject
    static func cutOut(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
            let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        } catch {
            return nil
        }
    }

    /// a made-up picture for the ui-shot (a plain shape on a transparent background, never a real photo)
    static func syntheticCutout() -> Loaded {
        let size = CGSize(width: 480, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { c in
            UIColor(red: 0.30, green: 0.34, blue: 0.40, alpha: 1).setFill()
            c.cgContext.fillEllipse(in: CGRect(x: 20, y: 150, width: 140, height: 140))
            c.cgContext.fillEllipse(in: CGRect(x: 320, y: 150, width: 140, height: 140))
            c.cgContext.fill(CGRect(x: 80, y: 130, width: 300, height: 30))
            c.cgContext.fill(CGRect(x: 360, y: 10, width: 26, height: 150))
        }
        return Loaded(image: img, cutout: true)
    }
}
