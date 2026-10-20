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
    /// F-31: a running charge timer replaces the % column; the Plugged in / Unplugged pill sits next to Connect
    var charge: ChargeSession?
    var chargeNowMs: Int64 = 0
    var utcOffsetMin = 0
    var onPlugged: (() -> Void)?
    var onEditCharge: () -> Void = {}
    @State private var connectTap = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme

    private let artSize = CGSize(width: 300, height: 294)

    init(name: String, connected: Bool, pct: Int?, caption: String?, odometerKm: Double?, colour: ScooterColour = .sand,
         photo: ScooterPhotoStore.Loaded? = nil, charge: ChargeSession? = nil, chargeNowMs: Int64 = 0, utcOffsetMin: Int = 0,
         onPlugged: (() -> Void)? = nil, onEditCharge: @escaping () -> Void = {}, onConnect: @escaping () -> Void = {}) {
        self.charge = charge
        self.chargeNowMs = chargeNowMs
        self.utcOffsetMin = utcOffsetMin
        self.onPlugged = onPlugged
        self.onEditCharge = onEditCharge
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
            HStack(spacing: 0) {
                Spacer(minLength: typeSize.isAccessibilitySize ? 60 : 150)
                if let charge {
                    VStack(alignment: .trailing, spacing: 6) {
                        ChargingBlock(session: charge, nowMs: chargeNowMs, utcOffsetMin: utcOffsetMin, onEdit: onEditCharge)
                        Spacer(minLength: 0)
                    }
                    .halo(photo != nil)
                    .environment(\.colorScheme, unedited ? ColorScheme.dark : scheme)
                } else {
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
                .environment(\.colorScheme, unedited ? ColorScheme.dark : scheme)
                }
            }
            .padding(.top, 24)
            .padding(.trailing, 20)
            if !connected {
                HStack(spacing: 10) {
                    if let onPlugged { ChargePill(charging: charge != nil, action: onPlugged).halo(photo != nil) }
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: charge != nil ? 380 : 310, alignment: .topLeading)
        .background(alignment: .topLeading) { art }     // a background never changes the card's size, so a wide photo cannot push the card off screen
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
    }

    /// P6-5: a photo that is shown as it is fills the whole card (text over it turns light)
    private var unedited: Bool { photo.map { !$0.useCut } ?? false }

    @ViewBuilder private var art: some View {
        if let photo {
            if photo.useCut, let cut = photo.cut {
                // a cut-out: full card height, exactly half of its width inside the card from the left edge
                let aspect = cut.size.height > 0 ? cut.size.width / cut.size.height : 1
                Image(uiImage: cut).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: artSize.height * aspect, height: artSize.height)
                    .offset(x: -artSize.height * aspect / 2, y: 8)
                    .accessibilityHidden(true)
            } else {
                // the photo as it is: the whole picture fills the card, framed by moving and zooming like a wallpaper
                FramedPhoto(image: photo.full, frame: photo.frame)
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

/// P6-5 (owner, 20 Oct): a photo aspect-filled into whatever box it is given, moved and zoomed by a `PhotoFrame` (fractions of the box, kept so
/// the photo always covers the box). Used by the hero card and by the framing sheet, so what is framed is what is shown.
struct FramedPhoto: View {
    let image: UIImage
    var frame: PhotoFrame

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1), h = max(g.size.height, 1)
            let imageAspect = image.size.height > 0 ? Double(image.size.width / image.size.height) : 1
            let f = frame.clamped(imageAspect: imageAspect, cardAspect: Double(w / h))
            let fillW = imageAspect > Double(w / h) ? h * CGFloat(imageAspect) : w
            let fillH = imageAspect > Double(w / h) ? h : w / CGFloat(imageAspect)
            Image(uiImage: image)
                .resizable()
                .frame(width: fillW * CGFloat(f.scale), height: fillH * CGFloat(f.scale))
                .position(x: w / 2 + CGFloat(f.dx) * w, y: h / 2 + CGFloat(f.dy) * h)
        }
        .clipped()
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
/// P6-5 (owner, 20 Oct): the photo is kept as it is by default (the whole picture fills the hero card, moved and zoomed to frame it); "Cut out
/// the scooter" is the alternative: Vision's foreground mask, made when it is switched on. A picture that already has a see-through background is
/// only ever shown cut out. The frame and the choice are small numbers in a file next to the picture.
enum ScooterPhotoStore {
    struct Loaded: @unchecked Sendable {
        /// the photo as picked (upright, at most 1600 px)
        var full: UIImage
        /// the cut-out, once there is one
        var cut: UIImage?
        /// true = show the cut-out
        var useCut: Bool
        var frame: PhotoFrame
        /// the picture itself has a see-through background
        var transparent: Bool
    }

    private struct Saved: Codable {
        var frame: PhotoFrame
        var cutout: Bool
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScooterHero", isDirectory: true)
    }
    private static var cutoutFile: URL { folder.appendingPathComponent("scooter-cutout.png") }
    private static var fullFile: URL { folder.appendingPathComponent("scooter-photo.jpg") }
    private static var stateFile: URL { folder.appendingPathComponent("scooter-frame.json") }

    static func load() -> Loaded? {
        let saved = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let cut = (try? Data(contentsOf: cutoutFile)).flatMap { UIImage(data: $0) }
        if let d = try? Data(contentsOf: fullFile), let i = UIImage(data: d) {
            return Loaded(full: i, cut: cut, useCut: (saved?.cutout ?? false) && cut != nil, frame: saved?.frame ?? PhotoFrame(), transparent: false)
        }
        // a photo stored by an older build or a picture that was see-through: only the cut-out exists
        if let cut { return Loaded(full: cut, cut: cut, useCut: true, frame: saved?.frame ?? PhotoFrame(), transparent: true) }
        return nil
    }

    static func remove() {
        try? FileManager.default.removeItem(at: cutoutFile)
        try? FileManager.default.removeItem(at: fullFile)
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// The picked picture, upright and at most 1600 px (nothing is stored yet); nil when it cannot be read.
    static func prepare(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let raw = UIImage(data: data) else { return nil }
            return normalized(raw, maxSide: 1600)
        }.value
    }

    /// Stores the framed photo. `cutout` true makes (or reuses) the cut-out; when Vision finds no subject the photo stays as it is.
    static func save(_ image: UIImage, frame: PhotoFrame, cutout: Bool, cut known: UIImage? = nil) async -> Loaded? {
        await Task.detached(priority: .userInitiated) { () -> Loaded? in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var dir = folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
                let transparent = hasTransparency(image)
                try? FileManager.default.removeItem(at: cutoutFile)
                if transparent {
                    guard let png = image.pngData() else { return nil }
                    try png.write(to: cutoutFile, options: .completeFileProtection)
                    try? FileManager.default.removeItem(at: fullFile)
                    try JSONEncoder().encode(Saved(frame: frame, cutout: true)).write(to: stateFile, options: .completeFileProtection)
                    return Loaded(full: image, cut: image, useCut: true, frame: frame, transparent: true)
                }
                guard let jpg = image.jpegData(compressionQuality: 0.85) else { return nil }
                try jpg.write(to: fullFile, options: .completeFileProtection)
                var cutImage: UIImage?
                if cutout { cutImage = known ?? cutOut(image) }
                if let cutImage, let png = cutImage.pngData() { try png.write(to: cutoutFile, options: .completeFileProtection) }
                let useCut = cutout && cutImage != nil
                try JSONEncoder().encode(Saved(frame: frame, cutout: useCut)).write(to: stateFile, options: .completeFileProtection)
                return Loaded(full: image, cut: cutImage, useCut: useCut, frame: frame, transparent: false)
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

    /// a made-up cut-out for the ui-shot (a plain shape on a transparent background, never a real photo)
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
        return Loaded(full: img, cut: img, useCut: true, frame: PhotoFrame(), transparent: true)
    }

    /// a made-up whole picture for the ui-shot (sky, ground and the same plain shape, never a real photo), wider than the card so it can be moved
    static func syntheticPhoto() -> Loaded {
        let size = CGSize(width: 900, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { c in
            let g = c.cgContext
            UIColor(red: 0.70, green: 0.82, blue: 0.93, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: size.width, height: 360))
            UIColor(red: 0.55, green: 0.58, blue: 0.52, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 360, width: size.width, height: 240))
            UIColor(red: 0.30, green: 0.34, blue: 0.40, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: 180, y: 330, width: 170, height: 170))
            g.fillEllipse(in: CGRect(x: 520, y: 330, width: 170, height: 170))
            g.fill(CGRect(x: 250, y: 320, width: 360, height: 34))
            g.fill(CGRect(x: 585, y: 120, width: 30, height: 210))
        }
        return Loaded(full: img, cut: nil, useCut: false, frame: PhotoFrame(), transparent: false)
    }
}

/// P6-5: after picking a photo (or from the menu): move and zoom the whole photo to frame it like a wallpaper, and optionally cut the scooter out.
/// The default is the photo as it is. Nothing is stored until Save.
struct PhotoFramingSheet: View {
    let image: UIImage
    let transparent: Bool
    @State var frame: PhotoFrame
    @State var cutout: Bool
    var existingCut: UIImage?
    let onSave: (PhotoFrame, Bool, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var base: PhotoFrame?
    @State private var baseZoom: Double?
    @State private var cut: UIImage?
    @State private var cutting = false
    @State private var noSubject = false

    private var imageAspect: Double { image.size.height > 0 ? Double(image.size.width / image.size.height) : 1 }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel", action: onCancel).frame(minHeight: DS.hit)
                Spacer()
                Text("Frame photo").font(.headline).fontDesign(.rounded)
                Spacer()
                Button("Save") { onSave(frame.clamped(imageAspect: imageAspect), cutout && !transparent && (cut ?? existingCut) != nil, cut ?? existingCut) }
                    .font(.body.weight(.semibold))
                    .frame(minHeight: DS.hit)
            }
            GeometryReader { g in
                let w = g.size.width
                let h = w / CGFloat(PhotoFrame.cardAspect)
                ZStack {
                    if cutout || transparent, let shown = cut ?? existingCut ?? (transparent ? image : nil) {
                        Image(uiImage: shown).resizable().aspectRatio(contentMode: .fit).padding(16)
                    } else {
                        FramedPhoto(image: image, frame: frame)
                            .gesture(drag(width: w, height: h))
                            .simultaneousGesture(zoom())
                    }
                    if cutting { ProgressView() }
                }
                .frame(width: w, height: h)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
                .accessibilityLabel("Photo preview. Drag to move, pinch to zoom")
            }
            .aspectRatio(CGFloat(PhotoFrame.cardAspect), contentMode: .fit)
            if !transparent {
                Toggle("Cut out the scooter", isOn: Binding(get: { cutout }, set: { setCutout($0) }))
                    .disabled(cutting)
                if noSubject { Text("No scooter found, the photo stays as it is.").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 8)
    }

    private func drag(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = base ?? frame
                base = start
                var f = start
                f.dx += Double(v.translation.width / max(width, 1))
                f.dy += Double(v.translation.height / max(height, 1))
                frame = f.clamped(imageAspect: imageAspect)
            }
            .onEnded { _ in base = nil }
    }

    private func zoom() -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = baseZoom ?? frame.scale
                baseZoom = start
                var f = frame
                f.scale = start * Double(v.magnification)
                frame = f.clamped(imageAspect: imageAspect)
            }
            .onEnded { _ in baseZoom = nil }
    }

    private func setCutout(_ on: Bool) {
        guard on else { cutout = false; noSubject = false; return }
        if cut != nil || existingCut != nil { cut = cut ?? existingCut; cutout = true; return }
        cutting = true
        noSubject = false
        let source = image
        Task {
            let result = await Task.detached(priority: .userInitiated) { ScooterPhotoStore.cutOut(source) }.value
            cutting = false
            if let result { cut = result; cutout = true } else { cutout = false; noSubject = true }
        }
    }
}

/// P6-5 (B43): the Scooter colour choice as a small sheet of the six real colours, a checkmark on the chosen one. (A menu tints its icons with
/// the accent, so every swatch looked orange.)
struct ScooterColourSheet: View {
    let selected: ScooterColour
    let onPick: (ScooterColour) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scooter colour").font(.headline).fontDesign(.rounded).padding(.top, 14)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                ForEach(ScooterColour.allCases, id: \.self) { c in
                    Button { onPick(c) } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(c.color)
                                .frame(width: 54, height: 54)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                .overlay {
                                    if c == selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(PlaceColours.glyphIsDark(hex: String(format: "#%06lX", c.hex)) ? Color(white: 0.1) : Color.white)
                                    }
                                }
                            Text(c.title).font(.footnote).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: DS.hit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .accessibilityAddTraits(c == selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            Spacer(minLength: 0)
        }
    }
}
