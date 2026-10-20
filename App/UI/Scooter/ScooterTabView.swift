import CorckieCore
import PhotosUI
import SwiftUI

/// M3-05: the Scooter tab. Status, info, links, and "Forget scooter" (clears the pairing only, never ride data).
struct ScooterTabView: View {
    /// Preview data for the ui-shot (no database, no Bluetooth).
    struct Preview {
        var record: ScooterRecord?
        var connected: Bool
        var lastSeenMs: Int64?
        var batteryPct: Int?
        var odometerKm: Double?
        /// V17: a made-up parked spot for the ui-shot
        var parked: ParkedSpot?
        var nowMs: Int64?
        /// F-26: the colour, and a made-up cut-out instead of a photo (ui-shot only)
        var colour: ScooterColour = .sand
        var samplePhoto = false
        /// P6-5: a made-up whole picture (unedited), and the colour sheet opened on its own
        var sampleUnedited = false
        var colourSheet = false
        /// F-31: a made-up running charge timer (ui-shot)
        var charge: ChargeSession?
    }

    var preview: Preview?
    @State private var record: ScooterRecord?
    @State private var odometerKm: Double?
    @State private var rows: [MaintenanceService.Row] = []
    @State private var parked: ParkedSpot?
    @State private var confirmForget = false
    @State private var customName: String?
    @State private var renaming = false
    @State private var nameText = ""
    @State private var colour: ScooterColour = .sand
    @State private var photo: ScooterPhotoStore.Loaded?
    @State private var pickingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    /// B43: the Scooter colour sheet
    @State private var showColours = false
    /// P6-5: the photo being framed (nil = no sheet)
    @State private var framing: FramingItem?
    /// F-31: the Plugged in sheet
    @State private var showCharge = false

    struct FramingItem: Identifiable {
        let id = UUID()
        var image: UIImage
        var transparent: Bool
        var frame: PhotoFrame
        var cutout: Bool
        var cut: UIImage?
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    private let link = AppModel.shared.scooter

    private var connected: Bool { preview?.connected ?? link.connected }
    private var paired: Bool { preview != nil ? preview?.record != nil : (link.hasKnownScooter || record != nil) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.block) {
                    if paired {
                        pairedCards
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "scooter").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No scooter paired").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .glassCard(radius: DS.Radius.hero, padding: 0)
                        .opacity(0.75)
                    }
                }
                .padding(DS.Space.gutter)
            }
            .background { MapBackdrop().ignoresSafeArea() }
            .navigationTitle("Scooter")
            .navigationBarTitleDisplayMode(.inline)   // G3
            .toolbar {
                if paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        // S4: Forget scooter lives behind the dots, not as a big red button on the page
                        Menu {
                            Button { nameText = customName ?? record?.name ?? ""; renaming = true } label: { Label("Rename scooter", systemImage: "pencil") }
                            Button { showColours = true } label: { Label("Scooter colour", systemImage: "circle.lefthalf.filled") }   // B43: a sheet of real swatches
                            Button { pickingPhoto = true } label: { Label("Choose photo", systemImage: "photo") }
                            if let p = photo { Button { framing = FramingItem(image: p.full, transparent: p.transparent, frame: p.frame, cutout: p.useCut, cut: p.cut) } label: { Label("Frame photo", systemImage: "crop") } }
                            if photo != nil { Button { removePhoto() } label: { Label("Remove photo", systemImage: "xmark.circle") } }
                            Button(role: .destructive) { confirmForget = true } label: { Label("Forget scooter", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .onAppear(perform: reload)
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedItem, matching: .images)
            .onChange(of: pickedItem) { _, item in if let item { Task { await usePicked(item) } } }
            .sheet(isPresented: $showCharge) {
                ChargeSheet(input: chargeInput()) { s in
                    if ChargeTimer.shared.session != nil { ChargeTimer.shared.update(s) } else { ChargeTimer.shared.begin(s) }
                }
                .glassPresentation(detents: [.large])
            }
            .sheet(isPresented: $showColours) {
                ScooterColourSheet(selected: colour) { c in setColour(c); showColours = false }
                    .glassPresentation(detents: [.height(300)])
            }
            .sheet(item: $framing) { item in
                PhotoFramingSheet(image: item.image, transparent: item.transparent, frame: item.frame, cutout: item.cutout, existingCut: item.cut,
                                  onSave: { frame, cutout, cut in
                                      framing = nil
                                      Task { await savePhoto(item.image, frame: frame, cutout: cutout, cut: cut) }
                                  }, onCancel: { framing = nil })
                    .glassPresentation(detents: [.large])
            }
            .alert("Rename scooter", isPresented: $renaming) {
                TextField("Name", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveName() }
            } message: {
                Text("Only this app shows the name. An empty name goes back to the Bluetooth name.")
            }
            .confirmationDialog("Forget this scooter?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget scooter", role: .destructive, action: forget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only the pairing is removed. Your rides, routes and maintenance stay.")
            }
            .screen("Scooter")
        }
    }

    @ViewBuilder private var pairedCards: some View {
        let rec = preview != nil ? preview?.record : record
        let seenMs: Int64? = preview != nil ? preview?.lastSeenMs : LastSeen.load().ms
        let seenPct: Int? = preview != nil ? preview?.batteryPct : LastSeen.load().pct
        let odo = preview != nil ? preview?.odometerKm : odometerKm
        let livePct: Int? = preview != nil ? preview?.batteryPct : AppModel.shared.settledBatteryPct
        let pct = connected ? (livePct ?? seenPct) : seenPct
        // F-26: the hero card (the line-art scooter enters from the left; name, battery %, caption, odometer and Connect on the right)
        let nowMs = preview?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        // F-31: a running charge timer (or the estimate it left when unplugged) replaces the last reading on the card
        let timer = ChargeTimer.shared
        let charge: ChargeSession? = preview != nil ? preview?.charge : timer.session
        let shown = Self.chargeAdjusted(pct: pct, caption: seenMs.map { Self.lastConnectedCaption($0, nowMs: nowMs) },
                                        unplugged: preview == nil && !connected && charge == nil ? timer.unplugged : nil, utcOffsetMin: timer.utcOffsetMin)
        ScooterHeroCard(name: customName ?? rec?.name ?? "Scooter", connected: connected, pct: shown.pct,
                        caption: shown.caption, odometerKm: odo,
                        colour: colour, photo: photo,
                        charge: charge, chargeNowMs: preview?.nowMs ?? timer.nowMs, utcOffsetMin: preview != nil ? 0 : timer.utcOffsetMin,
                        onPlugged: connected ? nil : { if preview != nil { return }; if charge != nil { timer.unplug() } else { showCharge = true } },
                        onEditCharge: { if preview == nil { showCharge = true } }) {
            if preview == nil { link.start() }
        }
        parkedRow
        // S3: one row: what is due next
        NavigationLink { MaintenanceView() } label: {
            HStack {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
                Spacer()
                if let next = Self.nextDue(rows) {
                    Text(next.text).font(.subheadline).foregroundStyle(next.due ? Theme.accentInk : Color.secondary)
                }
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
        NavigationLink { BatteryView() } label: {
            HStack {
                Label("Battery", systemImage: "battery.75percent")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
        }
        .buttonStyle(.plain)
    }

    /// F-31: after Unplugged the card keeps the line's estimate ("≈ 72 % · estimate when unplugged") until the real % is read
    static func chargeAdjusted(pct: Int?, caption: String?, unplugged: (pct: Double, ms: Int64)?, utcOffsetMin: Int) -> (pct: Int?, caption: String?) {
        guard let u = unplugged else { return (pct, caption) }
        return (Int(u.pct.rounded()), "\u{2248} estimate when unplugged \u{00B7} \(ChargeText.clock(u.ms, utcOffsetMin: utcOffsetMin))")
    }

    /// F-31: what the Plugged in sheet needs (the last reading, the rider's %/km, the usual trip)
    private func chargeInput() -> ChargeSheet.Input {
        let t = ChargeTimer.shared
        let name = customName ?? record?.name ?? "Scooter"
        let ctx = t.context(scooterName: name)
        let last = t.lastReading()
        return ChargeSheet.Input(scooterName: name, lastPct: last?.pct, lastMs: last?.ms, nowMs: t.now, utcOffsetMin: t.utcOffsetMin,
                                 pctPerKm: ctx.pctPerKm, reserve: ctx.reserve, usualNeed: ctx.usualNeed, usualName: ctx.usualName, editing: t.session)
    }

    /// V17: "Parked · Work · 2 h ago"; a tap opens the spot on a map
    @ViewBuilder private var parkedRow: some View {
        let spot = preview != nil ? preview?.parked : parked
        if let spot {
            let nowMs = preview?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            NavigationLink { ParkedMapView(spot: spot, nowMs: nowMs) } label: {
                HStack {
                    Label(ParkedText.line(spot, nowMs: nowMs), systemImage: "mappin.and.ellipse")
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a map")
        }
    }

    /// What is due next: an item that is due, else the one with the fewest km left ("Tyres \u{00B7} 120 km left")
    static func nextDue(_ rows: [MaintenanceService.Row]) -> (text: String, due: Bool)? {
        if let r = rows.first(where: { $0.status.isDue }) { return ("\(r.item.name) \u{00B7} \(Maintenance.statusText(r.status))", true) }
        let left: [(String, Double)] = rows.compactMap { r in
            if case .ok(let km) = r.status, let km { return (r.item.name, km) }
            return nil
        }
        guard let best = left.min(by: { $0.1 < $1.1 }) else { return nil }
        return ("\(best.0) \u{00B7} \(Int(best.1.rounded())) km left", false)
    }

    /// "When last connected · 6 h ago"; older than a day: the day and clock time
    static func lastConnectedCaption(_ ms: Int64, nowMs: Int64) -> String {
        let when = nowMs - ms < 24 * 3_600_000 ? ParkedText.ago(endedAtMs: ms, nowMs: nowMs) : lastSeenText(ms)
        return "When last connected \u{00B7} \(when)"
    }

    static func lastSeenText(_ ms: Int64?) -> String {
        guard let ms else { return "Not yet" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: date)
    }

    static func batteryText(_ pct: Int?, live: Bool) -> String {
        guard let pct else { return "Unknown" }
        return live ? "\(pct) %" : "\(pct) % (when last seen)"
    }

    private func reload() {
        if let p = preview {
            colour = p.colour
            photo = p.samplePhoto ? ScooterPhotoStore.syntheticCutout() : (p.sampleUnedited ? ScooterPhotoStore.syntheticPhoto() : nil)
            if p.colourSheet { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showColours = true } }
            return
        }
        guard let db = AppModel.shared.database else { return }
        colour = ScooterColour.from(stored: SettingsValue.text(db, ScooterColour.settingKey))
        photo = ScooterPhotoStore.load()
        record = ScooterRecord.latest(in: db)
        customName = SettingsValue.text(db, Self.nameKey)
        odometerKm = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        rows = MaintenanceService.rows(db)
        parked = ParkedResolver.current(database: db, simulated: false)   // B34: newest of the last ride end and the last-seen spot
    }

    private func setColour(_ c: ScooterColour) {
        colour = c
        guard preview == nil, let db = AppModel.shared.database else { return }
        SettingsValue.set(db, ScooterColour.settingKey, c.rawValue)
    }

    /// P6-5: the picked picture opens the framing sheet as it is (not cut out); it is stored on the phone only (P-2) when Save is tapped
    private func usePicked(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        guard preview == nil, let data = try? await item.loadTransferable(type: Data.self),
              let image = await ScooterPhotoStore.prepare(data) else { return }
        framing = FramingItem(image: image, transparent: ScooterPhotoStore.hasTransparency(image), frame: PhotoFrame(), cutout: false, cut: nil)
    }

    private func savePhoto(_ image: UIImage, frame: PhotoFrame, cutout: Bool, cut: UIImage?) async {
        if let loaded = await ScooterPhotoStore.save(image, frame: frame, cutout: cutout, cut: cut) { photo = loaded }
    }

    private func removePhoto() {
        ScooterPhotoStore.remove()
        photo = nil
    }

    private func saveName() {
        let t = String(nameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard preview == nil, let db = AppModel.shared.database else { return }
        if t.isEmpty { SettingsValue.clear(db, Self.nameKey); customName = nil } else { SettingsValue.set(db, Self.nameKey, t); customName = t }
    }

    /// app-only name; the scooter itself is never written to
    static let nameKey = "scooter.customName"

    private func forget() {
        link.forget()
        if let db = AppModel.shared.database { ScooterRecord.forgetPairing(in: db) }
        record = nil
    }
}

enum ScooterPreview {
    static func make(_ name: String) -> ScooterTabView.Preview? {
        let rec = ScooterRecord(id: "preview", name: "Scooter", chip: "chip", firmware: "1.2.3", software: "4.5", firstSeenAt: 0)
        switch name {
        case "scooter-tab": return .init(record: rec, connected: true, lastSeenMs: nil, batteryPct: 58, odometerKm: 412.3,
                                         parked: ParkedSpot(lat: 40.0, lon: -75.0, endedAtMs: 1_790_000_000_000 - 2 * 3_600_000, placeName: "Work"),
                                         nowMs: 1_790_000_000_000)
        case "scooter-tab-off": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000 - 7 * 3_600_000, batteryPct: 58, odometerKm: 412.3, nowMs: 1_790_000_000_000)
        case "scooter-tab-photo": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000 - 7 * 3_600_000, batteryPct: 65, odometerKm: 1059.6, nowMs: 1_790_000_000_000, colour: .sand, samplePhoto: true)
        case "scooter-tab-colours": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000 - 7 * 3_600_000, batteryPct: 65, odometerKm: 1059.6, nowMs: 1_790_000_000_000, colour: .moss, colourSheet: true)
        case "scooter-tab-photo-full": return .init(record: rec, connected: false, lastSeenMs: 1_790_000_000_000 - 7 * 3_600_000, batteryPct: 65, odometerKm: 1059.6, nowMs: 1_790_000_000_000, colour: .sand, sampleUnedited: true)
        case "scooter-tab-charging": return .init(record: rec, connected: false, lastSeenMs: ChargePreview.nowMs - 4 * 3_600_000, batteryPct: 18, odometerKm: 412.3, nowMs: ChargePreview.nowMs, charge: ChargePreview.session(.pct(80)))
        case "scooter-tab-none": return .init(record: nil, connected: false, lastSeenMs: nil, batteryPct: nil, odometerKm: nil)
        default: return nil
        }
    }
}
